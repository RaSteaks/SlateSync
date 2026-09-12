// SQLite extension for macOS Keychain access and the Swift client's flock
// protocol. Secret bytes stay inside the application process, never a CLI.
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1
#include <Security/Security.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static void key(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  const char *id = (const char *)sqlite3_value_text(argv[0]);
  CFStringRef account = CFStringCreateWithCString(NULL, id, kCFStringEncodingUTF8);
  const void *keys[] = {kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit};
  const void *values[] = {kSecClassGenericPassword, CFSTR("com.slatesync.local-project-encryption"), account, kCFBooleanTrue, kSecMatchLimitOne};
  CFDictionaryRef query = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching(query, &result);
  if (status == errSecSuccess && result && CFGetTypeID(result) == CFDataGetTypeID() && CFDataGetLength(result) == 32) {
    sqlite3_result_blob(ctx, CFDataGetBytePtr(result), 32, SQLITE_TRANSIENT);
  } else {
    char *message = sqlite3_mprintf("项目库密钥尚未解锁或已丢失（Keychain OSStatus %d）；请允许钥匙串访问，或恢复原钥匙串后重试。", (int)status);
    sqlite3_result_error(ctx, message, -1);
    sqlite3_free(message);
  }
  if (result) CFRelease(result);
  CFRelease(query);
  CFRelease(account);
}

static void lock_file(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  int fd = open((const char *)sqlite3_value_text(argv[0]), O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
  if (fd < 0) { sqlite3_result_error(ctx, "无法打开项目文件锁", -1); return; }
  if (fchmod(fd, 0600) != 0) { close(fd); sqlite3_result_error(ctx, "无法保护项目文件锁", -1); return; }
  for (int i = 0; i < 500; i++) {
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) { sqlite3_result_int(ctx, fd); return; }
    if (errno != EWOULDBLOCK && errno != EINTR) break;
    usleep(10000);
  }
  close(fd);
  sqlite3_result_error(ctx, "项目文件正由其他进程使用，请稍后重试", -1);
}

static void unlock_file(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  int fd = sqlite3_value_int(argv[0]);
  flock(fd, LOCK_UN);
  close(fd);
  sqlite3_result_null(ctx);
}

int sqlite3_localencryption_init(sqlite3 *db, char **error, const sqlite3_api_routines *api) {
  SQLITE_EXTENSION_INIT2(api);
  int rc = sqlite3_create_function(db, "slatesync_key", 1, SQLITE_UTF8 | SQLITE_DIRECTONLY, NULL, key, NULL, NULL);
  if (rc == SQLITE_OK) rc = sqlite3_create_function(db, "slatesync_lock", 1, SQLITE_UTF8 | SQLITE_DIRECTONLY, NULL, lock_file, NULL, NULL);
  if (rc == SQLITE_OK) rc = sqlite3_create_function(db, "slatesync_unlock", 1, SQLITE_UTF8 | SQLITE_DIRECTONLY, NULL, unlock_file, NULL, NULL);
  return rc;
}
