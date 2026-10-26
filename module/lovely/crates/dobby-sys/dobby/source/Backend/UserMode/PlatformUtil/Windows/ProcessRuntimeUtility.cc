#include "PlatformUtil/ProcessRuntimeUtility.h"

#include <vector>

#include <windows.h>

#define LINE_MAX 2048

// ================================================================
// GetProcessMemoryLayout

static bool memory_region_comparator(MemRegion a, MemRegion b) {
  return (a.start > b.start);
}

// https://gist.github.com/jedwardsol/9d4fe1fd806043a5767affbd200088ca

tinystl::vector<MemRegion> ProcessMemoryLayout;
const tinystl::vector<MemRegion> &ProcessRuntimeUtility::GetProcessMemoryLayout() {
  if (!ProcessMemoryLayout.empty()) {
    ProcessMemoryLayout.clear();
  }

  char *address{nullptr};
  MEMORY_BASIC_INFORMATION region;

  while (VirtualQuery(address, &region, sizeof(region))) {
    address += region.RegionSize;
    if (!(region.State & (MEM_COMMIT | MEM_RESERVE))) {
      continue;
    }

    MemoryPermission permission = MemoryPermission::kNoAccess;
    auto mask = PAGE_GUARD | PAGE_NOCACHE | PAGE_WRITECOMBINE;
    switch (region.Protect & ~mask) {
    case PAGE_NOACCESS:
    case PAGE_READONLY:
      break;

    case PAGE_EXECUTE:
    case PAGE_EXECUTE_READ:
      permission = MemoryPermission::kReadExecute;
      break;

    case PAGE_READWRITE:
    case PAGE_WRITECOPY:
      permission = MemoryPermission::kReadWrite;
      break;

    case PAGE_EXECUTE_READWRITE:
    case PAGE_EXECUTE_WRITECOPY:
      permission = MemoryPermission::kReadWriteExecute;
      break;
    }

    ProcessMemoryLayout.push_back(MemRegion{(addr_t)region.BaseAddress, region.RegionSize, permission});
  }
  return ProcessMemoryLayout;
}

// ================================================================
// GetProcessModuleMap

tinystl::vector<RuntimeModule> ProcessModuleMap;

const tinystl::vector<RuntimeModule> &ProcessRuntimeUtility::GetProcessModuleMap() {
  if (!ProcessModuleMap.empty()) {
    return ProcessModuleMap;
  }
  return ProcessModuleMap;
}

RuntimeModule ProcessRuntimeUtility::GetProcessModule(const char *name) {
  const tinystl::vector<RuntimeModule> &modules = GetProcessModuleMap();
  for (auto &module : modules) {
    if (strstr(module.path, name) != 0) {
      return module;
    }
  }
  return RuntimeModule{0};
}