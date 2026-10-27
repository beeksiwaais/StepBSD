# StepBSD login-shell setup, sourced from /etc/profile (sh) and /etc/zprofile
# (zsh, in sh emulation). Keep it POSIX sh.

# The GNUstep environment: GNUstep tools (defaults, openapp, gdnc, ...) on
# PATH, GNUSTEP_* set for gnustep-make.
if [ -r /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh ]; then
	. /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
fi

# The desktop starts by itself for a user logging in on the first virtual
# console (the live ISO logs `admin` in there automatically). Serial consoles,
# ssh, other VTs and root are left at the shell.
if [ -z "${DISPLAY:-}" ] && [ "$(id -u)" -ne 0 ] &&
   [ "$(/usr/bin/tty 2>/dev/null)" = /dev/ttyv0 ] &&
   [ ! -e "$HOME/.stepbsd-nodesktop" ] && [ -x /usr/local/bin/startstep ]; then
	echo "Starting the GNUstep desktop (touch ~/.stepbsd-nodesktop to stop this)..."
	/usr/local/bin/startstep
	echo "The desktop has exited. Type 'startstep' to start it again."
fi
