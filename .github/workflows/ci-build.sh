#!/bin/bash

# Github Action Continuous Integration for BuildRoot
# Author: Atom Long <atom.long@hotmail.com>

# Enable colors
if [[ -t 1 ]]; then
    normal='\e[0m'
    red='\e[1;31m'
    green='\e[1;32m'
    cyan='\e[1;36m'
fi

# Basic status function
_status() {
    local type="${1}"
    local status="${package:+${package}: }${2}"
    local items=("${@:3}")
    case "${type}" in
        failure) local -n nameref_color='red';   title='[BR2 CI] FAILURE:' ;;
        success) local -n nameref_color='green'; title='[BR2 CI] SUCCESS:' ;;
        message) local -n nameref_color='cyan';  title='[BR2 CI]'
    esac
    printf "\n${nameref_color}${title}${normal} ${status}\n\n"
    printf "${items:+\t%s\n}" "${items:+${items[@]}}"
}

# Get config information
_config_info() {
    local properties=("${@}")
    for property in "${properties[@]}"; do
        local -n nameref_property="${property}"
        nameref_property=($(
            source .config &>/dev/null
			[ -z ${nameref_property+x} ] && eval ${property}=$(sed -rn "s/^${property}(\w+)=y/\1/p" .config)
            declare -n nameref_property="${property}"
            echo "${nameref_property[@]}"))
    done
}

# Run command with status
execute(){
    local status="${1}"
    local command="${2}"
    local arguments=("${@:3}")
    message "${status}"
    if [[ "${command}" != *:* ]]; then
		${command} ${arguments[@]}
    else
		${command%%:*} | ${command#*:} ${arguments[@]}
    fi || failure "${status} failed"
}

# Status functions
failure() { local status="${1}"; local items=("${@:2}"); _status failure "${status}." "${items[@]}"; return 1; }
success() { local status="${1}"; local items=("${@:2}"); _status success "${status}." "${items[@]}"; return 0; }
message() { local status="${1}"; local items=("${@:2}"); _status message "${status}"  "${items[@]}"; }

# Install toolchain
install_toolchain()
{
local info toolchain_info toolchain_url
[ -n "${TOOLCHAIN_URL}" ] || { echo "TOOLCHAIN_URL is empty, skip install toolchain."; return 1; }
toolchain_url=$(eval echo "${TOOLCHAIN_URL}")
for info in $(find /opt -mindepth 2 -maxdepth 2 -type f -name "toolchain.info" 2>/dev/null); do
grep -Pq "^TOOLCHAIN_URL=\"${toolchain_url}\"" ${info} && { toolchain_info=${info}; break; }
done
[ -f "${toolchain_info}" ] && { source "${toolchain_info}"; return 0; }

curl -OL ${toolchain_url} || { echo "Failed to download toolchain. Please recheck variable 'TOOLCHAIN_URL'."; return 1; }
TOOLCHAIN_FILE=$(basename ${toolchain_url})
TOOLCHAIN_DIR=$(tar tvf ${TOOLCHAIN_FILE} | grep ^d  | awk -F/ '{if(NF<4) print }' | sed -rn 's|.*\s(\S+)/$|\1|p')
[ -n "${TOOLCHAIN_DIR}" ] || { echo "Invalid toolchain."; return 1; }
TOOLCHAIN_DIR=/opt/${TOOLCHAIN_DIR}
rm -rf ${TOOLCHAIN_DIR}
tar -xf ${TOOLCHAIN_FILE} -C /opt
rm -f ${TOOLCHAIN_FILE}
toolchain_info=${TOOLCHAIN_DIR}/toolchain.info
export PATH=${PATH}:${TOOLCHAIN_DIR}/bin/
TOOLCHAIN_PREFIX=$(ls ${TOOLCHAIN_DIR}/bin/*-gcc | sed -rn 's|.*/([^/]+)-gcc$|\1|p' | head -n 1)
TOOLCHAIN_GCC_VERSION=$(${TOOLCHAIN_PREFIX}-gcc --version | head -n 1 | sed -rn 's/.*\s+(\S+)$/\1/p')
TOOLCHAIN_LINUX_VERSION_CODE=$(sed -rn 's|#define\s+LINUX_VERSION_CODE\s+([0-9]+)|\1|p' $(${TOOLCHAIN_PREFIX}-gcc -print-sysroot)/usr/include/linux/version.h)
TOOLCHAIN_KERNEL_VERSION=$((TOOLCHAIN_LINUX_VERSION_CODE>>16 & 0xFF)).$((TOOLCHAIN_LINUX_VERSION_CODE>>8 & 0xFF)).$((TOOLCHAIN_LINUX_VERSION_CODE & 0xFF))
TOOLCHAIN_LIBC=$(sed -rn 's/^#\s*define\s+DEFAULT_LIBC\s+LIBC_(\w+)/\1/p' $(${TOOLCHAIN_PREFIX}-gcc -print-file-name=plugin)/include/tm.h)
BR2_TOOLCHAIN_EXTERNAL_INET_RPC=$( [ -f "$(${TOOLCHAIN_PREFIX}-gcc -print-sysroot)/usr/include/rpc/rpc.h" ] && echo "BR2_TOOLCHAIN_EXTERNAL_INET_RPC=y" || echo "# BR2_TOOLCHAIN_EXTERNAL_INET_RPC is not set")
BR2_TOOLCHAIN_EXTERNAL_CXX=$( ${TOOLCHAIN_PREFIX}-g++ -v > /dev/null 2>&1 && echo "BR2_TOOLCHAIN_EXTERNAL_CXX=y" || echo "# BR2_TOOLCHAIN_EXTERNAL_CXX is not set")

chmod 777 ${toolchain_info%/*}
echo "TOOLCHAIN_URL=\"${toolchain_url}\"" >> ${toolchain_info}
echo "TOOLCHAIN_DIR=\"${TOOLCHAIN_DIR}\"" >> ${toolchain_info}
echo "PATH=\${PATH}:\${TOOLCHAIN_DIR}/bin/" >> ${toolchain_info}
echo "TOOLCHAIN_PREFIX=\"${TOOLCHAIN_PREFIX}\"" >> ${toolchain_info}
echo "TOOLCHAIN_GCC_VERSION=\"${TOOLCHAIN_GCC_VERSION}\"" >> ${toolchain_info}
echo "TOOLCHAIN_LINUX_VERSION_CODE=\"${TOOLCHAIN_LINUX_VERSION_CODE}\"" >> ${toolchain_info}
echo "TOOLCHAIN_KERNEL_VERSION=\"${TOOLCHAIN_KERNEL_VERSION}\"" >> ${toolchain_info}
echo "TOOLCHAIN_LIBC=\"${TOOLCHAIN_LIBC}\"" >> ${toolchain_info}
echo "BR2_TOOLCHAIN_EXTERNAL_INET_RPC=\"${BR2_TOOLCHAIN_EXTERNAL_INET_RPC}\"" >> ${toolchain_info}
echo "BR2_TOOLCHAIN_EXTERNAL_CXX=\"${BR2_TOOLCHAIN_EXTERNAL_CXX}\"" >> ${toolchain_info}
}

# Build image
build_image()
{
[ -n "${board}" ] || { echo "var 'board' is empty."; return 1; }
[ -n "${branch}" ] || { echo "var 'branch' is empty."; return 1; }
[ -n "${DEPLOY_PATH}" ] || { echo "var 'DEPLOY_PATH' is empty."; return 1; }
local deploy_path=$(eval echo "${DEPLOY_PATH}")
local PATCH_DIR=${PWD}/boards/${board}/${branch}
local PATCH_ZIP=${PATCH_DIR}/patch.zip
local config

pushd linux
git clean -d -fx
git reset --hard HEAD
git checkout "${branch}"

local VERSION=$(sed -nr 's/^VERSION\s*=\s*([0-9]+)/\1/p' Makefile)
local PATCHLEVEL=$(sed -nr 's/^PATCHLEVEL\s*=\s*([0-9]+)/\1/p' Makefile)
local SUBLEVEL=$(sed -nr 's/^SUBLEVEL\s*=\s*([0-9]+)/\1/p' Makefile)
local VERSION="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}"
local RVERSION=$(rclone cat ${deploy_path}/VERSION 2>/dev/null)
[ "${VERSION}" == "${RVERSION}" ] && { echo "Version ${VERSION} is on remoter, skip building."; popd; return 0; }
[ -f ${PATCH_DIR}/config ] || { echo "No config for board '${board}' kernel '${branch}'."; popd; return 1; }

[ -f "${PATCH_ZIP}" ] && {
unzip -P "${ZIP_PASSWD}" -jo ${PATCH_ZIP} -d ${PATCH_DIR}
patch -Np1 -i ${PATCH_DIR}/*.patch
rm -vf ${PATCH_DIR}/*.patch
}
config=$(cat ${PATCH_DIR}/config)
make ARCH=arm CROSS_COMPILE=${TOOLCHAIN_PREFIX}- ${config}
make ARCH=arm CROSS_COMPILE=${TOOLCHAIN_PREFIX}- -j4
make ARCH=arm CROSS_COMPILE=${TOOLCHAIN_PREFIX}- -j4 INSTALL_MOD_PATH=modules modules
make ARCH=arm CROSS_COMPILE=${TOOLCHAIN_PREFIX}- -j4 INSTALL_MOD_PATH=modules modules_install
rm -vf modules/lib/modules/$(make kernelrelease)/{source,build}
popd
}

# deploy artifacts
deploy_artifacts()
{
[ -n "${board}" ] || { echo "var 'board' is empty."; return 1; }
[ -n "${branch}" ] || { echo "var 'branch' is empty."; return 1; }
[ -n "${DEPLOY_PATH}" ] || { echo "var 'DEPLOY_PATH' is empty."; return 1; }
local deploy_path=$(eval echo "${DEPLOY_PATH}")
local artifacts_dir=${PWD}/artifacts
local PATCH_DIR=${PWD}/boards/${board}/${branch}
local image=${PATCH_DIR}/image
local dtb=${PATCH_DIR}/dtb

echo "Deploy image files ..."
mkdir -pv ${artifacts_dir}
rm -vf ${artifacts_dir}/*
pushd linux
[ -s "${image}" ] && {
image=$(cat ${image})
[ -f "${image}" ] || { echo "No image to deploy"; popd; return 1; }
cp -vf "${image}" "${artifacts_dir}"
}

[ -s "${dtb}" ] && {
dtb=$(cat ${dtb})
[ -f "${dtb}" ] || { echo "No dtb to deploy"; popd; return 1; }
cp -vf "${dtb}" "${artifacts_dir}"
}

tar -C modules -czf modules.tar.gz lib
[ -f "modules.tar.gz" ] && {
cp -vf "modules.tar.gz" "${artifacts_dir}"
}

[ -n "$(ls ${artifacts_dir} -A)" ] || { echo "No file to deploy."; popd; return 1; }
pushd "${artifacts_dir}"
md5sum * > md5.sum
popd
rclone copy "${artifacts_dir}" "${deploy_path}" --copy-links

local VERSION=$(sed -nr 's/^VERSION\s*=\s*([0-9]+)/\1/p' Makefile)
local PATCHLEVEL=$(sed -nr 's/^PATCHLEVEL\s*=\s*([0-9]+)/\1/p' Makefile)
local SUBLEVEL=$(sed -nr 's/^SUBLEVEL\s*=\s*([0-9]+)/\1/p' Makefile)
local VERSION="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}"
echo "${VERSION}" | rclone rcat ${deploy_path}/VERSION
VERSIONs[${board}]+="<p>${VERSION}</p>"
popd
}

# download kernel sources
download_sources()
{
[ -n "${SOURCES_URL}" ] || { echo "Please set linux kernel source url via 'SOURCES_URL'."; return 1; }
[ -d "linux/.git" ] && {
pushd linux
git clean -d -fx
git reset --hard HEAD
git checkout master
while ! git pull --quiet --rebase origin master; do :; done
popd
return 0
}
rm -rf linux
git clone --progress -v "${SOURCES_URL}" "linux"
}

# create mail message
create_mail_message()
{
local message
for board in $(ls boards -A); do
[ -z "${VERSIONs[${board}]}" ] && continue
message+="<tr><td>${board}</td><td>${VERSIONs[${board}]}</td></tr>"
done
[ -n "${message}" ] || return 0
message="<p>The linux kernel has been builded successfully.</p>
<table border=\"1\">
<tr><th>Board Type</th><th>Linux Version</th></tr>
${message}
</table>
<p>Build Number: ${CI_BUILD_NUMBER}</p>
"
echo ::set-output name=message::${message}
[ -z "${GITHUB_ENV}" ] && {
local mailbody="\
From: \"${MAIL_USERNAME%@*}\" <${MAIL_USERNAME}>
To: \"${MAIL_TO%@*}\" <${MAIL_TO}>
Subject: Build Result
Content-Type: text/html; charset=\"utf-8\"

${message}
Bye!
"
echo "sending mail...."
echo "${mailbody}" | expect -c " \
set timeout 60
spawn telnet ${MAIL_HOST} ${MAIL_PORT}
expect -re \"220 .*\"
send \"HELO $(hostname)\r\"
expect -re \"250 OK\"
send \"AUTH LOGIN\r\"
expect -re \"334 .*\"
send \"$(printf ${MAIL_USERNAME} | base64)\r\"
expect -re \"334 .*\"
send \"$(printf ${MAIL_PASSWORD} | base64)\r\"
expect -re \"235 .*\"
send \"MAIL FROM: <${MAIL_USERNAME}>\r\"
expect -re \"250 OK\"
send \"RCPT TO: <${MAIL_TO}>\r\"
expect -re \"250 OK\"
send \"DATA\r\"
expect -re \"354 .*\"
set count 0
while {[gets stdin line]>=0} {
incr count
puts \"line \$count of body: \$line\"
send -- \"\$line\r\"
}
send \".\r\"
expect -re \"250 OK\"
send \"quit\r\"
expect -re \"221 Bye\"
"
}
return 0
}

# Run from here
message 'Install build environment.'

which apt &>/dev/null && sudo apt update -y
which pacman &>/dev/null && sudo pacman --sync --refresh

## install build tool
which make &>/dev/null || {
which apt &>/dev/null && sudo apt install build-essential -y
which pacman &>/dev/null && sudo pacman --sync --needed --noconfirm --disable-download-timeout base-devel
}
## install unzip
which unzip &>/dev/null || {
which apt &>/dev/null && sudo apt install unzip -y
which pacman &>/dev/null && sudo pacman -S --needed --noconfirm unzip
}
## install rclone
which rclone &>/dev/null || {
which apt &>/dev/null && sudo apt install rclone -y
which pacman &>/dev/null && sudo pacman -S --needed --noconfirm rclone
}
## install expect
which expect &>/dev/null || {
which apt &>/dev/null && sudo apt install expect -y
which pacman &>/dev/null && sudo pacman -S --needed --noconfirm expect
}
## install git
which git &>/dev/null || {
which apt &>/dev/null && sudo apt install git -y
which pacman &>/dev/null && sudo pacman -S --needed --noconfirm git
}

## Read environment variables
[ -z "${GITHUB_ENV}" ] && {
THIS_DIR=$(readlink -f "$(dirname ${0})")
BUILD_ZIP=${THIS_DIR}/build.zip
BUILD_CFG=${THIS_DIR}/build.config
unzip -jo ${BUILD_ZIP} -d ${THIS_DIR} || exit 1
[ -f "${BUILD_CFG}" ] && source ${BUILD_CFG} && rm -vf ${BUILD_CFG}
}

[ -z "${DEPLOY_PATH}" ] && { echo "Environment variable 'DEPLOY_PATH' is required."; exit 1; }
[ -z "${TOOLCHAIN_URL}" ] && { echo "Environment variable 'TOOLCHAIN_URL' is required."; exit 1; }
[ -z "${SOURCES_URL}" ] && { echo "Environment variable 'SOURCES_URL' is required."; exit 1; }
[ -z "${ZIP_PASSWD}" ] && { echo "Environment variable 'ZIP_PASSWD' is required."; exit 1; }

## configure rclone
RCLONE_CONFIG_PATH=$(rclone config file | tail -n1)
mkdir -pv ${RCLONE_CONFIG_PATH%/*}

[ -n "${GITHUB_ENV}" ] && {
[ -z "${RCLONE_CONF}" ] && { echo "Environment variable 'RCLONE_CONF' is required."; exit 1; }
[ -f ${RCLONE_CONFIG_PATH} ] || {
[ $(awk 'END{print NR}' <<< "${RCLONE_CONF}") == 1 ] &&
base64 --decode <<< "${RCLONE_CONF}" > ${RCLONE_CONFIG_PATH} ||
printf "${RCLONE_CONF}" > ${RCLONE_CONFIG_PATH}
}
} || {
[ -z "${RCLONE_CONF_ZIP_URL}" ] && { echo "Environment variable 'RCLONE_CONF_ZIP_URL' is required."; exit 1; }
CFG_TIME=$(stat -c "%X" ${RCLONE_CONFIG_PATH} 2>/dev/null || printf 0)
NOW_TIME=$(date "+%s")
(( NOW_TIME - CFG_TIME > 86400 )) && {
mv -vf  ${RCLONE_CONFIG_PATH}{,.orig} 2>/dev/null
RCLONE_CONF_ZIP=$(basename ${RCLONE_CONF_ZIP_URL})
curl -L ${RCLONE_CONF_ZIP_URL} -o ${RCLONE_CONF_ZIP}
while [ ! -f ${RCLONE_CONFIG_PATH} ]; do
unzip -zq ${RCLONE_CONF_ZIP} >/dev/stderr
FILE_PATH=$(unzip -jo ${RCLONE_CONF_ZIP} -d ${RCLONE_CONFIG_PATH%/*} | tail -n1 | awk '{print $2}')
[ -z "${FILE_PATH}" ] && continue
[ "${FILE_PATH}" == "${RCLONE_CONFIG_PATH}" ] || mv -vf ${FILE_PATH} ${RCLONE_CONFIG_PATH}
done
rm -vf ${RCLONE_CONF_ZIP} ${RCLONE_CONFIG_PATH}.orig
}
}

## download kernel source
cd ${CI_BUILD_DIR}
AE=$(git log --pretty=format:'%aE' HEAD^..)
AN=$(git log --pretty=format:'%aN' HEAD^..)
git config --global user.email ${AE}
git config --global user.name ${AN}
download_sources
success 'The build environment is ready successfully.'

# Build
declare -A VERSIONs
for board in $(ls boards -A); do
install_toolchain || { echo "Failed to install toolchain for board '${board}'."; exit 1; }
for branch in $(ls boards/${board} -A); do
execute "Building ${branch} for board ${board}" build_image
execute "Deploying ${branch} for board ${board}" deploy_artifacts
done
done
create_mail_message
success 'All artifacts have been deployed successfully'
