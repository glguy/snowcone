#!/bin/sh

# Usage: tmux-wrap.sh <command>
#
# Example TOML fragment
#
# password.command = "/path/to/tmux-wrap.sh"
# password.arguments = ["rbw get example"]
#
# This script runs a command in a separate tmux window and redirects that
# command's stderr, stdout, and exit code back to this script.
#
# By using it password managers that use pinentry-curses can run without
# disrupting your client's terminal

set -e

# Validate arguments
if [ -z "$1" ] || [ "$#" -ne 1 ]; then
  echo "Usage: $0 <command>" >&2
  exit 1
fi
COMMAND="$1"

# Ensure we're in a tmux session
if [ -z "$TMUX" ]; then
  echo "tmux session not detected" >&2
  exit 1
fi

# Allocate temporary directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TEMP_DIR}"' EXIT

# Create FIFOs
FIFO_exitcode="${TEMP_DIR}/exitcode"
FIFO_stderr="${TEMP_DIR}/stderr"
FIFO_stdout="${TEMP_DIR}/stdout"
mkfifo -m 600 "${FIFO_exitcode}"
mkfifo -m 600 "${FIFO_stderr}"
mkfifo -m 600 "${FIFO_stdout}"

tmux split-window "$COMMAND > ${FIFO_stdout} 2> ${FIFO_stderr}; echo \$? > ${FIFO_exitcode}"

# Proxy the command's stderr and stdout to this process
cat "${FIFO_stderr}" >&2 &
CAT_stderr=$!
cat "${FIFO_stdout}"
wait ${CAT_stderr}

# Proxy the exit code
read -r EXIT_CODE < "${FIFO_exitcode}"
exit "${EXIT_CODE}"
