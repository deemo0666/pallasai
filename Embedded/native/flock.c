#include <errno.h>
#include <node_api.h>
#include <sys/file.h>

static napi_value try_lock(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg, result;
    int32_t fd;
    if (napi_get_cb_info(env, info, &argc, &arg, NULL, NULL) != napi_ok ||
        argc != 1 || napi_get_value_int32(env, arg, &fd) != napi_ok) {
        napi_throw_type_error(env, NULL, "expected a file descriptor");
        return NULL;
    }
    int error = flock(fd, LOCK_EX | LOCK_NB) == 0 ? 0 : errno;
    napi_create_int32(env, error, &result);
    return result;
}

extern napi_value account_token(napi_env, napi_callback_info);
extern napi_value credential_document(napi_env, napi_callback_info);
extern napi_value image_codec(napi_env, napi_callback_info);
extern napi_value search_files(napi_env, napi_callback_info);

NAPI_MODULE_INIT() {
    napi_value function;
    napi_create_function(env, "tryLock", NAPI_AUTO_LENGTH, try_lock, NULL, &function);
    napi_set_named_property(env, exports, "tryLock", function);
    napi_create_function(env, "credentialDocument", NAPI_AUTO_LENGTH, credential_document, NULL, &function);
    napi_set_named_property(env, exports, "credentialDocument", function);
    napi_create_function(env, "accountToken", NAPI_AUTO_LENGTH, account_token, NULL, &function);
    napi_set_named_property(env, exports, "accountToken", function);
    napi_create_function(env, "search", NAPI_AUTO_LENGTH, search_files, NULL, &function);
    napi_set_named_property(env, exports, "search", function);
    napi_create_function(env, "imageCodec", NAPI_AUTO_LENGTH, image_codec, NULL, &function);
    napi_set_named_property(env, exports, "imageCodec", function);
    return exports;
}
