#!/bin/bash
# ============================================================
# offsets.sh — all offsets and original bytes for 580.178.04
#
# Pure variable definitions, no logic. Two ways to use it:
#   1. source it from a script
#   2. look things up by hand: "what needs patching in this version"
#
# ★ A new driver version requires re-locating everything;
#   do not copy these numbers.
# ============================================================

# ============================================================
# Version identity
# ============================================================
DRIVER_VERSION="580.178.04"
KERNEL_VERIFIED="6.12.113+deb13-amd64"
GPU_VERIFIED="P104-100 (10de:1b87)"

# ============================================================
# Target file paths
# ============================================================
# nvidia.ko (input of the gen2 patch)
KO_PATH="/lib/modules/$(uname -r)/updates/dkms/nvidia.ko"

# nv-kernel.o_binary (input of the whitelist patch, not the final module)
NVKERNEL_PATH="/usr/src/nvidia-580.178.04/nvidia/nv-kernel.o_binary"

# ============================================================
# gen2: 2 bytes, signature search
# ============================================================
# 32-byte signature, unique across the whole file. Patching by signature
# means absolute offsets do not matter.
#   Split view: 8d42ff | 4156 | 4155 | 4989fd | 4154 | 4531e4 | 53 |
#               4883ed40 | 48897510 | 89550c | 83f802 | 0f87
GEN2_SIG_HEX="8d42ff415641554989fd41544531e4534883ed404889751089550c83f8020f87"

GEN2_SIG_LEN=32

# The two positions inside the signature
GEN2_OFF_LEA=2      # the lea imm8
GEN2_ORIG_LEA=0xff
GEN2_NEW_LEA=0xfe

GEN2_OFF_CMP=0x1d   # the cmp imm8
GEN2_ORIG_CMP=0x02
GEN2_NEW_CMP=0x01

# md5
GEN2_MD5_BEFORE="7f6805ed15f1ae8122aa78e65a5d48a0"
GEN2_MD5_AFTER="514de9d4fdd7c407a088f1baf4b62f04"

# ============================================================
# whitelist: 5 dwords, fixed offset
# ============================================================
WHITELIST_OFFSET=0x5cfdfcc

# The 5 entries' original device IDs (low 16 bits)
WHITELIST_DEV_IDS=(0x1b07 0x1b87 0x1bc7 0x1c07 0x1c09)

# Model names matching the list above one-to-one (from pci.ids, display only)
WHITELIST_DEV_NAMES=("P102-100" "P104-100" "P104-101" "P106-100" "P106-090")

# Family prefix (high 16 bits), preserved on replacement
WHITELIST_FAMILY=0x0007

# Sentinel value after replacement
WHITELIST_SENTINEL=0xffff

# md5 (of nv-kernel.o_binary)
WHITELIST_MD5_BEFORE="caa613d35d8bdfd615cee91e932689b5"
WHITELIST_MD5_AFTER="f3480248f7a70f7501fd14ac90582ef1"

# ============================================================
# File sizes (a quick "is this the right version" check)
# ============================================================
KO_SIZE=157271160
NVKERNEL_SIZE=112677456
