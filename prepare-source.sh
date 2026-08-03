#!/usr/bin/env bash
# Prepare a clean LineageOS 22.2 joan kernel tree with KernelSU-Next legacy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-${ROOT}/kernel}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_lge_msm8998.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-22.2}"
KSU_REF="${KSU_REF:-legacy}"

if [[ -e "${KERNEL_DIR}" ]]; then
  echo "Refusing to overwrite existing ${KERNEL_DIR}" >&2
  exit 1
fi

# Avoid mutating the user's global Git configuration.
git_config="$(mktemp)"
trap 'rm -f "${git_config}"' EXIT
export GIT_CONFIG_GLOBAL="${git_config}"
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000

for attempt in 1 2 3; do
  echo "[+] Cloning ${KERNEL_REPO} (${KERNEL_BRANCH}), attempt ${attempt}/3"
  if git clone --depth 1 --single-branch -b "${KERNEL_BRANCH}" \
      "${KERNEL_REPO}" "${KERNEL_DIR}"; then
    break
  fi
  rm -rf "${KERNEL_DIR}"
  [[ "${attempt}" -lt 3 ]] || { echo 'Kernel source clone failed.' >&2; exit 1; }
  sleep 5
done

echo "[+] Integrating KernelSU-Next (${KSU_REF})"
(
  cd "${KERNEL_DIR}"
  curl --fail --location --silent --show-error \
    https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh \
    | bash -s "${KSU_REF}"
)

# This Linux 4.4 tree lacks __nocfi; it has no CFI instrumentation, so the
# annotation can be safely dropped for the legacy build.
sed -i 's/static int __nocfi my_sel_open_handle_status/static int my_sel_open_handle_status/' \
  "${KERNEL_DIR}/drivers/kernelsu/feature/selinux_hide.c"

echo "[+] Applying project patches"
patch --batch --fuzz=0 -d "${KERNEL_DIR}" -p1 < "${ROOT}/patches/post-kernelsu.diff"
patch --batch --fuzz=0 -d "${KERNEL_DIR}" -p1 < "${ROOT}/patches/manual-hooks-linux-4.4.diff"

# The resolved ref is the actual KernelSU revision used by this build.
printf '[+] KernelSU-Next resolved commit: '
git -C "${KERNEL_DIR}/KernelSU-Next" rev-parse HEAD

# Verify that the strict manual integration—not tracepoint/kprobe mode—is present.
for hook in ksu_handle_execveat ksu_handle_faccessat ksu_handle_vfs_read \
            ksu_handle_stat ksu_handle_newfstat_ret ksu_handle_fstat64_ret \
            ksu_handle_setresuid ksu_handle_sys_reboot; do
  grep -Rqs "${hook}" "${KERNEL_DIR}/fs" "${KERNEL_DIR}/kernel" || {
    echo "Missing manual hook: ${hook}" >&2
    exit 1
  }
done

echo "[+] Source prepared in ${KERNEL_DIR}"
