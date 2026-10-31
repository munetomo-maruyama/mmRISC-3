# riscv_arch_test.h : tests/env/riscv_arch_test.h for the mmRISC-3 bench (Plan/CORE.md 5.7):
# act_sig_macros.h in place of sail_macros.h. The quoted include finds this
# copy first (-I act comes before -I tests/env).
# The original:
# Top-level riscv-arch-test header file
# Jordan Carlin jcarlin@hmc.edu October 2025
# SPDX-License-Identifier: Apache-2.0

#include "rvtest_config.h"
#include "derived_config.h"
#include "encoding.h"
#ifdef ENABLE_EXPERIMENTAL_EXTENSIONS
  #include "rvtest_experimental.h"
#endif
#include "utils.h"
#include "rvmodel_macros.h"
#ifndef RVTEST_SELFCHECK
  #include "act_sig_macros.h"
#endif
#include "check_defines.h"
#include "signature.h"
#include "rvtest_macros.h"
#if UDB_NUM_PMP_ENTRIES > 0
  #include "rvtest_pmp_macros.h"
#endif
#ifdef RVTEST_VECTOR
  #include "rvtest_macros_vector.h"
#endif
#ifdef H_SUPPORTED
  #include "rvtest_macros_hypervisor.h"
#endif
#include "rvtest_trap_handler.h"
#include "rvtest_invisible_trap_handler.h"
#include "rvtest_failure_code.h"
#include "rvtest_setup.h"
