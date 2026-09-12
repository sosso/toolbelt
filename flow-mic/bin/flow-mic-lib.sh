#!/bin/bash
# Shared configuration, sourced by the other flow-mic scripts. Adjust MIC for
# your hardware — `micctl list` shows device names.
#
# MOTIV Mix Virtual exposes a mute control but it is read-only; the physical
# MV7+ is the settable one, so that is the device the whole tool drives.
MIC="Shure MV7+"
MICCTL="$HOME/.local/bin/micctl"
STATE="$HOME/.local/state/wispr-mic-state"
FLAG="$HOME/.local/state/wispr-dictating"
