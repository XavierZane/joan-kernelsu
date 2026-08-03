#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${ROOT}/kernel"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_lge_msm8998.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-22.2}"
# KernelSU Next tag/branch for non-GKI 4.4.x (see kernelsu-next installation docs)
KSU_REF="${KSU_REF:-legacy}"

if [[ -e "${KERNEL_DIR}" ]]; then
  echo "Refusing to overwrite existing ${KERNEL_DIR}" >&2
  exit 1
fi

echo "[+] Cloning ${KERNEL_REPO} (${KERNEL_BRANCH})"
# The LineageOS kernel repository is large; HTTP/1.1 plus retries avoids
# transient HTTP/2 sideband disconnects on GitHub-hosted runners.
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000
for attempt in 1 2 3; do
  if git clone --depth 1 --single-branch -b "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${KERNEL_DIR}"; then
    break
  fi
  rm -rf "${KERNEL_DIR}"
  if [[ "${attempt}" -eq 3 ]]; then
    echo "Kernel clone failed after ${attempt} attempts" >&2
    exit 1
  fi
  echo "[!] Kernel clone failed; retrying (${attempt}/3)" >&2
  sleep 5
done

echo "[+] Integrating KernelSU Next (${KSU_REF})"
(
  cd "${KERNEL_DIR}"
  curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "${KSU_REF}"
)

# KernelSU-Next uses ALIGN_DOWN(), which is unavailable in this Linux 4.4
# tree. Keep the equivalent 8-byte alignment local to adb_root.c.
sed -i \
  -e 's@ALIGN_DOWN(stackp - sizeof(kLdPreload), 8)@((stackp - sizeof(kLdPreload)) \& ~7UL)@' \
  -e 's@ALIGN_DOWN(stackp - sizeof(kLdLibraryPath), 8)@((stackp - sizeof(kLdLibraryPath)) \& ~7UL)@' \
  "${KERNEL_DIR}/drivers/kernelsu/feature/adb_root.c"

echo "[+] Applying local post-KernelSU Next patches"
patch -d "${KERNEL_DIR}" -p1 < "${ROOT}/patches/post-kernelsu.diff"
patch -d "${KERNEL_DIR}" -p1 < "${ROOT}/patches/manual-hooks-linux-4.4.diff"

echo "[+] Source prepared in ${KERNEL_DIR}"
