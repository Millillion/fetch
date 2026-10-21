/*
 * Native transports for the Fetch package.
 *
 * Under Lasm (Lean compiled to WebAssembly for Node.js, __EMSCRIPTEN__), requests
 * go to Node's global fetch through the Lean runtime's host call ABI
 * (lasm_node_call / lasm_node_copy / lasm_node_release, operations 190-192).
 *
 * Natively, libcurl is loaded at run time with dlopen/LoadLibrary (no build-time
 * dependency on libcurl or its headers). When it is unavailable, the Lean side
 * falls back to the curl command-line tool.
 */
#include <lean/lean.h>
#include <stdint.h>
#include <stddef.h>

/* Lean's bundled C compiler ships only freestanding headers: declare the few C
   library functions used here (every Lean program links the C library). */
void *malloc(size_t size);
void *realloc(void *pointer, size_t size);
void *calloc(size_t count, size_t size);
void free(void *pointer);
void *memcpy(void *destination, const void *source, size_t size);
int memcmp(const void *a, const void *b, size_t size);
void *memchr(const void *s, int c, size_t size);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
char *getenv(const char *name);

static int ascii_lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int prefix_case(const char *s, const char *prefix) {
    for (; *prefix; s++, prefix++) if (ascii_lower((unsigned char)*s) != *prefix) return 0;
    return 1;
}
static int parse_int(const char *s) { int n = 0; while (*s >= '0' && *s <= '9') n = 10 * n + (*s++ - '0'); return n; }

static lean_obj_res fetch_error(const char *message) {
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(message)));
}

static lean_obj_res mk_pair(lean_obj_arg a, lean_obj_arg b) {
    lean_object *o = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(o, 0, a); lean_ctor_set(o, 1, b);
    return o;
}
static lean_obj_res mk_some(lean_obj_arg a) {
    lean_object *o = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(o, 0, a);
    return o;
}
static lean_obj_res mk_bytes(const uint8_t *data, size_t size) {
    lean_object *o = lean_alloc_sarray(1, size, size);
    if (size) memcpy(lean_sarray_cptr(o), data, size);
    return o;
}

#ifdef __EMSCRIPTEN__
/* ---------------------------------------------------------------- Lasm / Node */
#define FETCH_BACKEND 1
extern int64_t lasm_node_call(uint32_t operation, uint32_t handle, uint64_t argument, const uint8_t *input, size_t length);
extern void lasm_node_copy(uint8_t *output, size_t length);
extern void lasm_node_release(uint32_t handle);

typedef struct { int failed; uint8_t *bytes; size_t size; } reply_t;
static reply_t host_call(uint32_t op, uint32_t handle, const uint8_t *input, size_t length) {
    reply_t r;
    int64_t n = lasm_node_call(op, handle, 0, input, length);
    r.failed = n < 0;
    r.size = r.failed ? (size_t)(-(n + 1)) : (size_t)n;
    r.bytes = (uint8_t *)malloc(r.size ? r.size : 1);
    lasm_node_copy(r.bytes, r.size);
    return r;
}
/* Host failures carry [u64 kind][u64 errno][message]. */
static lean_obj_res host_error(reply_t r) {
    lean_object *message = r.size >= 16 ? lean_mk_string_from_bytes((const char *)r.bytes + 16, r.size - 16)
                                          : lean_mk_string("fetch failed");
    free(r.bytes);
    return lean_io_result_mk_error(lean_mk_io_user_error(message));
}

typedef struct { uint32_t handle; } node_body_t;
static void node_body_finalize(void *p) {
    node_body_t *body = (node_body_t *)p;
    if (body->handle) lasm_node_release(body->handle);
    free(body);
}
static void node_body_foreach(void *handle, b_lean_obj_arg f) { (void)handle; (void)f; }
static lean_external_class *node_body_class = NULL;
static lean_external_class *node_class(void) {
    if (!node_body_class) node_body_class = lean_register_external_class(node_body_finalize, node_body_foreach);
    return node_body_class;
}

/* (request : @& String) (body : @& ByteArray) : IO (NodeBody × String) */
LEAN_EXPORT lean_obj_res fetch_shim_node_start(b_lean_obj_arg request, b_lean_obj_arg body) {
   
    size_t json = lean_string_size(request) - 1, size = lean_sarray_size(body);
    uint8_t *input = (uint8_t *)malloc(4 + json + size);
    input[0] = json & 0xff; input[1] = (json >> 8) & 0xff; input[2] = (json >> 16) & 0xff; input[3] = (json >> 24) & 0xff;
    memcpy(input + 4, lean_string_cstr(request), json);
    if (size) memcpy(input + 4 + json, lean_sarray_cptr(body), size);
    reply_t r = host_call(190, 0, input, 4 + json + size);
    free(input);
    if (r.failed) return host_error(r);
    /* The reply is JSON; the Lean side reads the handle from it. */
    lean_object *head = lean_mk_string_from_bytes((const char *)r.bytes, r.size);
    free(r.bytes);
    return lean_io_result_mk_ok(head);
}

/* (handle : UInt32) : IO NodeBody — owns the host resource from now on. */
LEAN_EXPORT lean_obj_res fetch_shim_node_adopt(uint32_t handle) {
   
    node_body_t *body = (node_body_t *)malloc(sizeof(node_body_t));
    body->handle = handle;
    return lean_io_result_mk_ok(lean_alloc_external(node_class(), body));
}

/* (body : @& NodeBody) : IO (Option ByteArray) */
LEAN_EXPORT lean_obj_res fetch_shim_node_read(b_lean_obj_arg body) {
   
    uint32_t handle = ((node_body_t *)lean_get_external_data(body))->handle;
    if (!handle) return lean_io_result_mk_ok(lean_box(0));
    reply_t r = host_call(191, handle, NULL, 0);
    if (r.failed) return host_error(r);
    lean_object *result = r.size >= 1 && r.bytes[0] == 1 ? mk_some(mk_bytes(r.bytes + 1, r.size - 1)) : lean_box(0);
    free(r.bytes);
    return lean_io_result_mk_ok(result);
}

/* (body : @& NodeBody) : IO Unit — cancels the stream now (the finalizer would later). */
LEAN_EXPORT lean_obj_res fetch_shim_node_close(b_lean_obj_arg body) {
   
    node_body_t *state = (node_body_t *)lean_get_external_data(body);
    if (state->handle) { uint32_t handle = state->handle; state->handle = 0; lasm_node_release(handle); }
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res fetch_shim_curl_start(b_lean_obj_arg url, b_lean_obj_arg method, b_lean_obj_arg headers, b_lean_obj_arg body,
    uint8_t has_body, uint8_t follow, uint64_t timeout_ms) {
    (void)url; (void)method; (void)headers; (void)body; (void)has_body; (void)follow; (void)timeout_ms;
    return fetch_error("libcurl is not available in WebAssembly");
}
LEAN_EXPORT lean_obj_res fetch_shim_curl_available(void) { return lean_io_result_mk_ok(lean_box(0)); }
LEAN_EXPORT lean_obj_res fetch_shim_curl_head(b_lean_obj_arg h) { (void)h; return fetch_error("libcurl is not available"); }
LEAN_EXPORT lean_obj_res fetch_shim_curl_read(b_lean_obj_arg h) { (void)h; return fetch_error("libcurl is not available"); }
LEAN_EXPORT lean_obj_res fetch_shim_curl_close(b_lean_obj_arg h) { (void)h; return lean_io_result_mk_ok(lean_box(0)); }

#else
/* ------------------------------------------------------- native: libcurl */
#define FETCH_BACKEND 0
#ifdef _WIN32
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *name);
__declspec(dllimport) void *__stdcall GetProcAddress(void *module, const char *name);
#define dl_open(name) LoadLibraryA(name)
#define dl_sym(lib, name) GetProcAddress(lib, name)
#else
void *dlopen(const char *file, int mode);
void *dlsym(void *handle, const char *name);
#ifdef __APPLE__
#define FETCH_RTLD_NOW 0x2
#define FETCH_RTLD_LOCAL 0x4
#else
#define FETCH_RTLD_NOW 0x2
#define FETCH_RTLD_LOCAL 0
#endif
#define dl_open(name) dlopen(name, FETCH_RTLD_NOW | FETCH_RTLD_LOCAL)
#define dl_sym(lib, name) dlsym(lib, name)
#endif

/* The stable libcurl ABI (curl/curl.h): option and info numbers. */
typedef void CURL;
typedef void CURLM;
struct curl_slist { char *data; struct curl_slist *next; };
typedef struct { int msg; CURL *easy_handle; union { void *whatever; int result; } data; } CURLMsg;
enum { CURLOPT_WRITEDATA = 10001, CURLOPT_URL = 10002, CURLOPT_POSTFIELDS = 10015, CURLOPT_USERAGENT = 10018,
       CURLOPT_HTTPHEADER = 10023, CURLOPT_HEADERDATA = 10029, CURLOPT_CUSTOMREQUEST = 10036, CURLOPT_ACCEPT_ENCODING = 10102,
       CURLOPT_WRITEFUNCTION = 20011, CURLOPT_HEADERFUNCTION = 20079, CURLOPT_POSTFIELDSIZE_LARGE = 30120,
       CURLOPT_NOBODY = 44, CURLOPT_FOLLOWLOCATION = 52, CURLOPT_MAXREDIRS = 68, CURLOPT_NOSIGNAL = 99,
       CURLOPT_TIMEOUT_MS = 155 };
enum { CURLINFO_EFFECTIVE_URL = 0x100001, CURLINFO_RESPONSE_CODE = 0x200002, CURLINFO_REDIRECT_COUNT = 0x200014 };
enum { CURLMSG_DONE = 1, CURL_GLOBAL_DEFAULT = 3, CURLE_OPERATION_TIMEDOUT = 28 };

static struct {
    int loaded, available;
    int (*global_init)(long);
    CURL *(*easy_init)(void);
    int (*easy_setopt)(CURL *, int, ...);
    int (*easy_getinfo)(CURL *, int, ...);
    void (*easy_cleanup)(CURL *);
    const char *(*easy_strerror)(int);
    CURLM *(*multi_init)(void);
    int (*multi_add_handle)(CURLM *, CURL *);
    int (*multi_remove_handle)(CURLM *, CURL *);
    int (*multi_perform)(CURLM *, int *);
    int (*multi_wait)(CURLM *, void *, unsigned, int, int *);
    CURLMsg *(*multi_info_read)(CURLM *, int *);
    int (*multi_cleanup)(CURLM *);
    struct curl_slist *(*slist_append)(struct curl_slist *, const char *);
    void (*slist_free_all)(struct curl_slist *);
} curl;

static void load_curl(void) {
    if (curl.loaded) return;
    curl.loaded = 1;
    const char *names[] = { getenv("FETCH_LIBCURL"),
#ifdef _WIN32
        "libcurl.dll", "libcurl-x64.dll", "libcurl-4.dll",
#elif defined(__APPLE__)
        "libcurl.4.dylib", "/usr/lib/libcurl.4.dylib", "libcurl.dylib",
#else
        "libcurl.so.4", "libcurl-gnutls.so.4", "libcurl-nss.so.4", "libcurl.so",
#endif
        NULL };
    void *lib = NULL;
    for (size_t i = 0; !lib && i < sizeof(names) / sizeof(names[0]); i++) if (names[i] && *names[i]) lib = dl_open(names[i]);
    if (!lib) return;
#define LOAD(field, symbol) if (!(*(void **)&curl.field = dl_sym(lib, symbol))) return
    LOAD(global_init, "curl_global_init"); LOAD(easy_init, "curl_easy_init"); LOAD(easy_setopt, "curl_easy_setopt");
    LOAD(easy_getinfo, "curl_easy_getinfo"); LOAD(easy_cleanup, "curl_easy_cleanup"); LOAD(easy_strerror, "curl_easy_strerror");
    LOAD(multi_init, "curl_multi_init"); LOAD(multi_add_handle, "curl_multi_add_handle");
    LOAD(multi_remove_handle, "curl_multi_remove_handle"); LOAD(multi_perform, "curl_multi_perform");
    LOAD(multi_wait, "curl_multi_wait"); LOAD(multi_info_read, "curl_multi_info_read"); LOAD(multi_cleanup, "curl_multi_cleanup");
    LOAD(slist_append, "curl_slist_append"); LOAD(slist_free_all, "curl_slist_free_all");
#undef LOAD
    if (curl.global_init(CURL_GLOBAL_DEFAULT) != 0) return;
    curl.available = 1;
}

typedef struct {
    CURL *easy; CURLM *multi; struct curl_slist *headers;
    uint8_t *request_body;
    uint8_t *data; size_t size, capacity;      /* received body bytes not yet read */
    char *head; size_t head_size, head_capacity; /* header lines of the current response */
    int status, head_complete, done, result, follow, nobody, closed;
} transfer_t;

static void append(uint8_t **buffer, size_t *size, size_t *capacity, const void *data, size_t length) {
    if (*size + length + 1 > *capacity) {
        size_t next = *capacity ? *capacity : 4096;
        while (next < *size + length + 1) next *= 2;
        *buffer = (uint8_t *)realloc(*buffer, next); *capacity = next;
    }
    memcpy(*buffer + *size, data, length); *size += length; (*buffer)[*size] = 0;
}

static size_t on_header(char *line, size_t size, size_t count, void *user) {
    transfer_t *t = (transfer_t *)user;
    size_t length = size * count;
    if (length >= 5 && memcmp(line, "HTTP/", 5) == 0) {
        /* A new response (1xx, a redirect hop, or the final one): start over. */
        t->head_size = 0;
        const char *space = memchr(line, ' ', length);
        t->status = space ? parse_int(space + 1) : 0;
    }
    if (length <= 2 && (line[0] == '\r' || line[0] == '\n')) {
        int redirect = t->status == 301 || t->status == 302 || t->status == 303 || t->status == 307 || t->status == 308;
        int has_location = 0;
        for (size_t i = 0; i + 9 < t->head_size; i++)
            if ((i == 0 || t->head[i - 1] == '\n') && prefix_case(t->head + i, "location:")) { has_location = 1; break; }
        if (t->status >= 200 && !(t->follow && redirect && has_location)) t->head_complete = 1;
        return length;
    }
    append((uint8_t **)&t->head, &t->head_size, &t->head_capacity, line, length);
    return length;
}

static size_t on_data(char *data, size_t size, size_t count, void *user) {
    transfer_t *t = (transfer_t *)user;
    t->head_complete = 1;
    append(&t->data, &t->size, &t->capacity, data, size * count);
    return size * count;
}

/* Drive the transfer until `ready(t)` or it finishes. Returns 0, or an error result. */
static int pump(transfer_t *t, int (*ready)(transfer_t *)) {
    while (!t->done && !ready(t)) {
        int running = 0;
        curl.multi_perform(t->multi, &running);
        int pending;
        CURLMsg *message;
        while ((message = curl.multi_info_read(t->multi, &pending)))
            if (message->msg == CURLMSG_DONE) { t->done = 1; t->result = message->data.result; t->head_complete = 1; }
        if (t->done || ready(t)) break;
        curl.multi_wait(t->multi, NULL, 0, 1000, NULL);
    }
    return t->result;
}
static int head_ready(transfer_t *t) { return t->head_complete; }
static int data_ready(transfer_t *t) { return t->size > 0; }

static void transfer_release(transfer_t *t) {
    if (t->closed) return;
    t->closed = 1;
    if (t->multi) { curl.multi_remove_handle(t->multi, t->easy); curl.multi_cleanup(t->multi); }
    if (t->easy) curl.easy_cleanup(t->easy);
    if (t->headers) curl.slist_free_all(t->headers);
    free(t->request_body); free(t->data); free(t->head);
    t->multi = NULL; t->easy = NULL; t->headers = NULL; t->request_body = NULL; t->data = NULL; t->head = NULL;
}
static void transfer_free(transfer_t *t) { transfer_release(t); free(t); }
static void curl_body_finalize(void *p) { if (p) transfer_free((transfer_t *)p); }
static void curl_body_foreach(void *p, b_lean_obj_arg f) { (void)p; (void)f; }
static lean_external_class *curl_body_class = NULL;

static lean_obj_res curl_failure(transfer_t *t) {
    if (t->result == CURLE_OPERATION_TIMEDOUT) return fetch_error("request timed out");
    const char *reason = curl.easy_strerror(t->result);
    size_t length = strlen(reason);
    char *message = (char *)malloc(length + 7);
    memcpy(message, "curl: ", 6); memcpy(message + 6, reason, length + 1);
    lean_obj_res failure = fetch_error(message);
    free(message);
    return failure;
}

LEAN_EXPORT lean_obj_res fetch_shim_curl_available(void) {
    load_curl();
    return lean_io_result_mk_ok(lean_box(curl.available));
}

/* (url method : @& String) (headers : @& Array String) (body : @& ByteArray) (hasBody follow : UInt8)
   (timeoutMs : UInt64) : IO CurlBody — returns once the final response's headers have arrived. */
LEAN_EXPORT lean_obj_res fetch_shim_curl_start(b_lean_obj_arg url, b_lean_obj_arg method, b_lean_obj_arg headers, b_lean_obj_arg body,
    uint8_t has_body, uint8_t follow, uint64_t timeout_ms) {
    load_curl();
    if (!curl.available) return fetch_error("libcurl is not available");
    transfer_t *t = (transfer_t *)calloc(1, sizeof(transfer_t));
    t->easy = curl.easy_init(); t->multi = curl.multi_init(); t->follow = follow;
    if (!t->easy || !t->multi) { transfer_free(t); return fetch_error("curl: cannot create a transfer"); }
    const char *m = lean_string_cstr(method);
    curl.easy_setopt(t->easy, CURLOPT_URL, lean_string_cstr(url));
    curl.easy_setopt(t->easy, CURLOPT_NOSIGNAL, 1L);
    curl.easy_setopt(t->easy, CURLOPT_ACCEPT_ENCODING, "");
    curl.easy_setopt(t->easy, CURLOPT_USERAGENT, "lean-fetch/0.1");
    curl.easy_setopt(t->easy, CURLOPT_FOLLOWLOCATION, (long)(follow ? 1 : 0));
    curl.easy_setopt(t->easy, CURLOPT_MAXREDIRS, 20L);
    if (timeout_ms) curl.easy_setopt(t->easy, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
    if (strcmp(m, "HEAD") == 0) { curl.easy_setopt(t->easy, CURLOPT_NOBODY, 1L); t->nobody = 1; }
    else if (strcmp(m, "GET") != 0 || has_body) curl.easy_setopt(t->easy, CURLOPT_CUSTOMREQUEST, m);
    if (has_body) {
        size_t size = lean_sarray_size(body);
        t->request_body = (uint8_t *)malloc(size ? size : 1);
        if (size) memcpy(t->request_body, lean_sarray_cptr(body), size);
        curl.easy_setopt(t->easy, CURLOPT_POSTFIELDSIZE_LARGE, (long long)size);
        curl.easy_setopt(t->easy, CURLOPT_POSTFIELDS, t->request_body);
    }
    size_t count = lean_array_size(headers);
    for (size_t i = 0; i < count; i++) t->headers = curl.slist_append(t->headers, lean_string_cstr(lean_array_get_core(headers, i)));
    t->headers = curl.slist_append(t->headers, "Expect:");
    curl.easy_setopt(t->easy, CURLOPT_HTTPHEADER, t->headers);
    curl.easy_setopt(t->easy, CURLOPT_HEADERFUNCTION, on_header);
    curl.easy_setopt(t->easy, CURLOPT_HEADERDATA, t);
    curl.easy_setopt(t->easy, CURLOPT_WRITEFUNCTION, on_data);
    curl.easy_setopt(t->easy, CURLOPT_WRITEDATA, t);
    curl.multi_add_handle(t->multi, t->easy);
    if (pump(t, head_ready) != 0) { lean_obj_res failure = curl_failure(t); transfer_free(t); return failure; }
    if (!curl_body_class) curl_body_class = lean_register_external_class(curl_body_finalize, curl_body_foreach);
    return lean_io_result_mk_ok(lean_alloc_external(curl_body_class, t));
}

/* (body : @& CurlBody) : IO (UInt32 × String × UInt32 × String): status, effective URL,
   redirect count and the final response's raw header lines. */
LEAN_EXPORT lean_obj_res fetch_shim_curl_head(b_lean_obj_arg handle) {
   
    transfer_t *t = (transfer_t *)lean_get_external_data(handle);
    long code = 0, redirects = 0; char *effective = NULL;
    curl.easy_getinfo(t->easy, CURLINFO_RESPONSE_CODE, &code);
    curl.easy_getinfo(t->easy, CURLINFO_EFFECTIVE_URL, &effective);
    curl.easy_getinfo(t->easy, CURLINFO_REDIRECT_COUNT, &redirects);
    lean_object *head = lean_mk_string_from_bytes(t->head ? t->head : "", t->head_size);
    lean_object *rest = mk_pair(lean_box_uint32((uint32_t)redirects), head);
    rest = mk_pair(lean_mk_string(effective ? effective : ""), rest);
    return lean_io_result_mk_ok(mk_pair(lean_box_uint32((uint32_t)(code ? code : t->status)), rest));
}

/* (body : @& CurlBody) : IO (Option ByteArray) */
LEAN_EXPORT lean_obj_res fetch_shim_curl_read(b_lean_obj_arg handle) {
   
    transfer_t *t = (transfer_t *)lean_get_external_data(handle);
    if (t->closed) return lean_io_result_mk_ok(lean_box(0));
    if (pump(t, data_ready) != 0 && t->size == 0) return curl_failure(t);
    if (t->size == 0) return lean_io_result_mk_ok(lean_box(0));
    lean_object *chunk = mk_bytes(t->data, t->size);
    t->size = 0;
    return lean_io_result_mk_ok(mk_some(chunk));
}

LEAN_EXPORT lean_obj_res fetch_shim_curl_close(b_lean_obj_arg handle) {
   
    transfer_release((transfer_t *)lean_get_external_data(handle));
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res fetch_shim_node_start(b_lean_obj_arg request, b_lean_obj_arg body) {
    (void)request; (void)body;
    return fetch_error("the Node fetch backend is only available under Lasm");
}
LEAN_EXPORT lean_obj_res fetch_shim_node_adopt(uint32_t handle) { (void)handle; return fetch_error("the Node fetch backend is only available under Lasm"); }
LEAN_EXPORT lean_obj_res fetch_shim_node_read(b_lean_obj_arg h) { (void)h; return fetch_error("the Node fetch backend is only available under Lasm"); }
LEAN_EXPORT lean_obj_res fetch_shim_node_close(b_lean_obj_arg h) { (void)h; return lean_io_result_mk_ok(lean_box(0)); }
#endif

/* Which transport this build has: 1 = Lasm/Node fetch, 0 = native (libcurl, then the curl tool). */
LEAN_EXPORT uint8_t fetch_shim_backend(lean_obj_arg unit) { (void)unit; return FETCH_BACKEND; }
