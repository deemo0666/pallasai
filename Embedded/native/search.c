#include <node_api.h>
#include <stdlib.h>
#include <string.h>

// native/search: ripgrep's libraries behind the two command lines the engine's glob and grep tools build.
extern char *dsh_search(const char *request, const unsigned char *cancel);
extern void dsh_search_free(char *answer);

typedef struct {
    napi_async_work work;
    napi_deferred deferred;
    napi_ref cancelRef;
    const unsigned char *cancel;
    char *request;
    char *answer;
} Search;

static void run_search(napi_env env, void *data) {
    Search *search = data;
    search->answer = dsh_search(search->request, search->cancel);
}

static void finish_search(napi_env env, napi_status status, void *data) {
    Search *search = data;
    napi_value value;
    if (status == napi_ok && search->answer &&
        napi_create_string_utf8(env, search->answer, NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, search->deferred, value);
    } else {
        napi_value message, error;
        napi_create_string_utf8(env, "native search failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, NULL, message, &error);
        napi_reject_deferred(env, search->deferred, error);
    }
    dsh_search_free(search->answer);
    napi_delete_reference(env, search->cancelRef);
    napi_delete_async_work(env, search->work);
    free(search->request);
    free(search);
}

/// search(request: JSON string, cancel: Uint8Array of one byte) -> Promise<JSON string>.
/// Runs off the JavaScript thread; the caller sets cancel[0] to give up.
napi_value search_files(napi_env env, napi_callback_info info) {
    napi_value args[2], promise, name;
    size_t count = 2, length = 0, cancelLength = 0;
    void *cancel = NULL;
    napi_typedarray_type type;
    if (napi_get_cb_info(env, info, &count, args, NULL, NULL) != napi_ok || count != 2 ||
        napi_get_value_string_utf8(env, args[0], NULL, 0, &length) != napi_ok ||
        napi_get_typedarray_info(env, args[1], &type, &cancelLength, &cancel, NULL, NULL) != napi_ok ||
        type != napi_uint8_array || cancelLength < 1) {
        napi_throw_type_error(env, NULL, "expected a request string and a Uint8Array");
        return NULL;
    }
    Search *search = calloc(1, sizeof(Search));
    search->request = malloc(length + 1);
    napi_get_value_string_utf8(env, args[0], search->request, length + 1, NULL);
    search->cancel = cancel;
    // Keeps the byte the worker thread reads alive until it has finished.
    napi_create_reference(env, args[1], 1, &search->cancelRef);
    napi_create_promise(env, &search->deferred, &promise);
    napi_create_string_utf8(env, "dshSearch", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, NULL, name, run_search, finish_search, search, &search->work);
    napi_queue_async_work(env, search->work);
    return promise;
}
