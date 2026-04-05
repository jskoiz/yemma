// Copyright 2025 Google LLC.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

#ifndef LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#define LITERT_BUILD_COMMON_BUILD_CONFIG_H_

#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
#include "litert/build_common/config/build_config_cpu_only.h"
#else
#include "litert/build_common/config/build_config_gpu.h"
#endif

#endif  // LITERT_BUILD_COMMON_BUILD_CONFIG_H_
