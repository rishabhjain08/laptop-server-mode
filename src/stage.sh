# Sourced by the .sh wrappers in the repo root. Windows can't always see
# WSL's files (\\wsl.localhost is missing when the distro was started outside
# your sign-in), so scripts are copied to a temporary Windows folder first, and
# Windows programs are started from a Windows folder. Sets PS, STAGE (WSL path)
# and STAGE_WIN; the folder is removed on exit.
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[ -x "$PS" ] || { echo "Windows PowerShell not found. Is WSL interop enabled?" >&2; exit 1; }
cd /mnt/c
STAGE_WIN="$(/mnt/c/Windows/System32/cmd.exe /c 'echo %TEMP%' | tr -d '\r')\\lsm-$$"
STAGE="$(wslpath -u "$STAGE_WIN")"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
