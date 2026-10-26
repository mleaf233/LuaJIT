#include "dobby/dobby_internal.h"
#include "Interceptor.h"

#ifndef _MSC_VER
__attribute__((constructor)) static void ctor() {
  DEBUG_LOG("================================");
  DEBUG_LOG("Dobby");
  DEBUG_LOG("dobby in debug log mode, disable with cmake flag \"-DDOBBY_DEBUG=OFF\"");
  DEBUG_LOG("================================");
}
#else
// MSVC does not support __attribute__((constructor)). The ctor is purely a
// debug log on library load; on Windows the loader still maps the static
// library, so omitting the constructor has no functional impact.
static void ctor() {
  DEBUG_LOG("================================");
  DEBUG_LOG("Dobby");
  DEBUG_LOG("dobby in debug log mode, disable with cmake flag \"-DDOBBY_DEBUG=OFF\"");
  DEBUG_LOG("================================");
}
#endif

PUBLIC const char *DobbyGetVersion() {
  return "";
}

PUBLIC int DobbyDestroy(void *address) {
#if defined(TARGET_ARCH_ARM)
  if ((addr_t)address % 2) {
    address = (void *)((addr_t)address - 1);
  }
#endif
  auto entry = Interceptor::SharedInstance()->find((addr_t)address);
  if (entry) {
    uint8_t *buffer = entry->origin_insns;
    uint32_t buffer_size = entry->origin_insn_size;
    DobbyCodePatch(address, buffer, buffer_size);
    Interceptor::SharedInstance()->remove((addr_t)address);
    return 0;
  }

  return -1;
}
