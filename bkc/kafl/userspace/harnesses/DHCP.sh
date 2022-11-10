#!/bin/sh

# 
# Copyright (C)  2022  Intel Corporation. 
#
# This software and the related documents are Intel copyrighted materials, and your use of them is governed by the express license under which they were provided to you ("License"). Unless the License provides otherwise, you may not use, modify, copy, publish, distribute, disclose or transmit this software or the related documents without Intel's prior written permission.
# This software and the related documents are provided as is, with no express or implied warranties, other than those that are expressly stated in the License.
#
# SPDX-License-Identifier: MIT

mount -t debugfs none /sys/kernel/debug/
KAFL_CTL=/sys/kernel/debug/kafl

echo "[*] kAFL userspace harness DHCP. Agent status:"
grep . $KAFL_CTL/*
grep . $KAFL_CTL/status/*

# guest prepare
ip link
ip link set eth0 up

# BEGIN HARNESS
echo "enable"  > $KAFL_CTL/control

udhcpc 2>&1 |hcat

## END HARNESS
echo "done"  > $KAFL_CTL/control
