/**
 * ausock.c — baresip audio module using a Unix domain socket
 *
 * Bridges baresip audio with an external process (Ruby AudioBridge)
 * via a single full-duplex Unix stream socket.
 *
 * Audio format: raw S16LE samples (baresip internal format)
 * Socket protocol: full-duplex byte stream
 *   - C writes caller audio (auplay wh → socket)
 *   - C reads  agent audio  (socket → ausrc rh)
 *
 * The module creates a listening socket at /tmp/ausock.sock (or
 * AUSOCK_PATH env) on load.  The external process connects once;
 * both directions share the single fd.
 */

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>

#include <re.h>
#include <rem.h>
#include <baresip.h>

#define DEFAULT_PATH "/tmp/ausock.sock"

/* ------------------------------------------------------------------ */
/*  Module-level state                                                 */
/* ------------------------------------------------------------------ */

static struct ausrc  *mod_ausrc;
static struct auplay *mod_auplay;

static int   listen_fd = -1;
static int   client_fd = -1;
static mtx_t sock_mtx;
static char  sock_path[256];

/* ------------------------------------------------------------------ */
/*  Per-instance state                                                 */
/* ------------------------------------------------------------------ */

struct ausrc_st {
	bool           run;
	thrd_t         thread;
	ausrc_read_h  *rh;
	ausrc_error_h *errh;
	void          *arg;
	uint32_t       ptime;   /* ms  */
	uint32_t       sampc;   /* samples per frame */
	uint32_t       srate;
};

struct auplay_st {
	bool            run;
	thrd_t          thread;
	auplay_write_h *wh;
	void           *arg;
	uint32_t        ptime;
	uint32_t        sampc;
	uint32_t        srate;
};

/* ------------------------------------------------------------------ */
/*  Socket helpers                                                     */
/* ------------------------------------------------------------------ */

static int setup_listen(const char *path)
{
	struct sockaddr_un addr;
	int fd;

	unlink(path);

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return errno;

	/* non-blocking so accept() in get_client() never blocks */
	fcntl(fd, F_SETFL, O_NONBLOCK);

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
	    listen(fd, 5) < 0) {
		int err = errno;
		close(fd);
		return err;
	}

	listen_fd = fd;
	strncpy(sock_path, path, sizeof(sock_path) - 1);
	return 0;
}

/**
 * Return the connected client fd, accepting a new connection
 * if none exists.  Returns -1 if no client is connected.
 */
static int get_client(void)
{
	int fd;

	mtx_lock(&sock_mtx);
	fd = client_fd;
	mtx_unlock(&sock_mtx);

	if (fd >= 0)
		return fd;

	/* try non-blocking accept */
	fd = accept(listen_fd, NULL, NULL);
	if (fd < 0)
		return -1;

	/* make the data socket blocking */
	fcntl(fd, F_SETFL, 0);

#ifdef SO_NOSIGPIPE          /* macOS */
	{
		int val = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
			   &val, sizeof(val));
	}
#endif

	mtx_lock(&sock_mtx);
	if (client_fd >= 0) {
		/* race: another thread accepted first */
		close(fd);
		fd = client_fd;
	} else {
		client_fd = fd;
	}
	mtx_unlock(&sock_mtx);

	return fd;
}

static void drop_client(int fd)
{
	mtx_lock(&sock_mtx);
	if (client_fd == fd) {
		close(fd);
		client_fd = -1;
	}
	mtx_unlock(&sock_mtx);
}

static uint64_t clock_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000;
}

/* ------------------------------------------------------------------ */
/*  ausrc — audio source (agent → caller)                             */
/*                                                                     */
/*  A thread reads S16LE frames from the socket and pushes them into   */
/*  baresip's encode pipeline via rh().                                */
/* ------------------------------------------------------------------ */

static int src_thread(void *arg)
{
	struct ausrc_st *st = arg;
	const size_t nbytes = st->sampc * sizeof(int16_t);
	const uint64_t ptime_us = st->ptime * 1000;
	uint64_t next_frame;
	int16_t *buf;

	buf = mem_zalloc(nbytes, NULL);
	if (!buf)
		return thrd_error;

	next_frame = clock_us();

	while (st->run) {
		struct auframe af;
		uint64_t now;
		int fd = get_client();

		if (fd >= 0) {
			struct pollfd pfd = {
				.fd = fd, .events = POLLIN
			};

			/* Wait for data but no longer than until our
			   next frame boundary so rh() stays on cadence */
			now = clock_us();
			int timeout_ms = 0;
			if (next_frame > now)
				timeout_ms = (int)((next_frame - now) / 1000);

			int ret = poll(&pfd, 1, timeout_ms);

			if (ret > 0 && (pfd.revents & POLLIN)) {
				size_t off = 0;

				while (off < nbytes) {
					ssize_t n = read(fd,
							 (char *)buf + off,
							 nbytes - off);
					if (n <= 0) {
						drop_client(fd);
						memset((char *)buf + off, 0,
						       nbytes - off);
						break;
					}
					off += (size_t)n;
				}
			} else {
				/* no data yet — push silence */
				memset(buf, 0, nbytes);
			}
		} else {
			/* no client yet */
			memset(buf, 0, nbytes);
		}

		/* pace rh() on a monotonic clock */
		next_frame += ptime_us;
		now = clock_us();
		if (next_frame > now)
			usleep((unsigned)(next_frame - now));
		else
			next_frame = now;  /* fell behind, reset */

		auframe_init(&af, AUFMT_S16LE, buf,
			     st->sampc, st->srate, 1);
		st->rh(&af, st->arg);
	}

	mem_deref(buf);
	return thrd_success;
}

static void src_destructor(void *data)
{
	struct ausrc_st *st = data;

	st->run = false;
	thrd_join(st->thread, NULL);
}

static int src_alloc(struct ausrc_st **stp, const struct ausrc *as,
		     struct ausrc_prm *prm, const char *device,
		     ausrc_read_h *rh, ausrc_error_h *errh, void *arg)
{
	struct ausrc_st *st;
	int err;
	(void)as;
	(void)device;

	st = mem_zalloc(sizeof(*st), src_destructor);
	if (!st)
		return ENOMEM;

	st->rh    = rh;
	st->errh  = errh;
	st->arg   = arg;
	st->srate = prm->srate;
	st->ptime = prm->ptime;
	st->sampc = prm->srate * prm->ch * prm->ptime / 1000;
	st->run   = true;

	err = thread_create_name(&st->thread, "ausock_src",
				 src_thread, st);
	if (err) {
		mem_deref(st);
		return err;
	}

	*stp = st;
	return 0;
}

/* ------------------------------------------------------------------ */
/*  auplay — audio player (caller → agent)                            */
/*                                                                     */
/*  A thread pulls decoded S16LE frames from baresip via wh() and      */
/*  writes them to the socket.                                         */
/* ------------------------------------------------------------------ */

static int play_thread(void *arg)
{
	struct auplay_st *st = arg;
	const size_t nbytes = st->sampc * sizeof(int16_t);
	const uint64_t ptime_us = st->ptime * 1000;
	uint64_t next_frame;
	int16_t *buf;

	buf = mem_zalloc(nbytes, NULL);
	if (!buf)
		return thrd_error;

	next_frame = clock_us();

	while (st->run) {
		struct auframe af;
		uint64_t now;
		int fd;

		auframe_init(&af, AUFMT_S16LE, buf,
			     st->sampc, st->srate, 1);

		/* pull decoded audio from baresip */
		st->wh(&af, st->arg);

		fd = get_client();
		if (fd >= 0) {
			size_t off = 0;

			while (off < nbytes) {
				ssize_t n = write(fd,
						  (char *)buf + off,
						  nbytes - off);
				if (n <= 0) {
					drop_client(fd);
					break;
				}
				off += (size_t)n;
			}
		}

		/* sleep until next 20 ms boundary (drift-free) */
		next_frame += ptime_us;
		now = clock_us();
		if (next_frame > now)
			usleep((unsigned)(next_frame - now));
		else
			next_frame = now;  /* fell behind, reset */
	}

	mem_deref(buf);
	return thrd_success;
}

static void play_destructor(void *data)
{
	struct auplay_st *st = data;

	st->run = false;
	thrd_join(st->thread, NULL);
}

static int play_alloc(struct auplay_st **stp, const struct auplay *ap,
		      struct auplay_prm *prm, const char *device,
		      auplay_write_h *wh, void *arg)
{
	struct auplay_st *st;
	int err;
	(void)ap;
	(void)device;

	st = mem_zalloc(sizeof(*st), play_destructor);
	if (!st)
		return ENOMEM;

	st->wh    = wh;
	st->arg   = arg;
	st->srate = prm->srate;
	st->ptime = prm->ptime;
	st->sampc = prm->srate * prm->ch * prm->ptime / 1000;
	st->run   = true;

	err = thread_create_name(&st->thread, "ausock_play",
				 play_thread, st);
	if (err) {
		mem_deref(st);
		return err;
	}

	*stp = st;
	return 0;
}

/* ------------------------------------------------------------------ */
/*  Module entry points                                                */
/* ------------------------------------------------------------------ */

static int module_init(void)
{
	const char *path;
	int err;

	signal(SIGPIPE, SIG_IGN);

	err = mtx_init(&sock_mtx, mtx_plain);
	if (err != thrd_success)
		return ENOMEM;

	path = getenv("AUSOCK_PATH");
	if (!path || !*path)
		path = DEFAULT_PATH;

	err = setup_listen(path);
	if (err) {
		mtx_destroy(&sock_mtx);
		return err;
	}

	err  = ausrc_register(&mod_ausrc, baresip_ausrcl(),
			      "ausock", src_alloc);
	err |= auplay_register(&mod_auplay, baresip_auplayl(),
				"ausock", play_alloc);

	if (err) {
		mod_ausrc  = mem_deref(mod_ausrc);
		mod_auplay = mem_deref(mod_auplay);
	}

	return err;
}

static int module_close(void)
{
	mod_ausrc  = mem_deref(mod_ausrc);
	mod_auplay = mem_deref(mod_auplay);

	if (client_fd >= 0) {
		close(client_fd);
		client_fd = -1;
	}

	if (listen_fd >= 0) {
		close(listen_fd);
		listen_fd = -1;
	}

	if (sock_path[0])
		unlink(sock_path);

	mtx_destroy(&sock_mtx);

	return 0;
}

EXPORT_SYM const struct mod_export exports = {
	.name  = "ausock",
	.type  = "ausrc",
	.init  = module_init,
	.close = module_close,
};
