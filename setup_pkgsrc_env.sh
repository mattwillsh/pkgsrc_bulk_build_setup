#!/bin/bash
#
# Scriptification of http://www.perkin.org.uk/posts/distributed-chrooted-pkgsrc-bulk-builds.html
#
# (c) Jonathan Perkin, 2013
# (c) Matt Willsher <matt@monki.org.uk>, 2013
#
# Work in progress!
#

# Edit these
PKGSRC_BRANCH='2013Q2' # pkgsrc branch to use
PROVIDER_NAME='monki' # This can be a LANANA name or similar. Used for folder under /opt

# These are default paths
CONTENT_ROOT='/content' # Root of content tree
PROVIDER_DIR="${PROVIDER_NAME}/" 
OPT_PATH="/opt/${PROVIDER_DIR}local" # Path for /, /etc and /var anchoring
PBULK_PATH="/opt/${PROVIDER_DIR}pbulk" # Location for pbulk install
CHROOT_PATH="/chroot"

PKGSRC_REPO='https://github.com/jsonn/pkgsrc' # Where to get pkgsrc tree from

set -e
set -x

if [[ $EUID != 0 ]]; then
  echo "Script needs to be run as root"
  exit 1
fi

export SH=/bin/bash

mkdir -p ${CONTENT_ROOT}/{distfiles,mk,packages/bootstrap,scripts}

[[ -f ${CONTENT_ROOT}/mk/mk-generic.conf ]] ||
  cat >${CONTENT_ROOT}/mk/mk-generic.conf <<EOF
ALLOW_VULNERABLE_PACKAGES=	yes
SKIP_LICENSE_CHECK=		yes
DISTDIR=			${CONTENT_ROOT}/distfiles

# If your system has a native curl, this avoids building nbftp
FAILOVER_FETCH=		yes
FETCH_USING=		curl

# Change this to a closer mirror (http://www.netbsd.org/mirrors)
MASTER_SITE_OVERRIDE=	ftp://ftp.nl.NetBSD.org/pub/NetBSD/packages/distfiles/

# Tweak this for your system, though take into account how many concurrent
# chroots you may want to run too.
MAKE_JOBS=		4
EOF

cat >${CONTENT_ROOT}/mk/mk-pbulk.conf <<EOF
.include "${CONTENT_ROOT}/mk/mk-generic.conf"

PACKAGES=	${CONTENT_ROOT}/packages/${PKGSRC_BRANCH}/pbulk
WRKOBJDIR=	/var/tmp/pkgbuild
EOF

cat >${CONTENT_ROOT}/mk/mk-pkg.conf <<EOF
.include "${CONTENT_ROOT}/mk/mk-generic.conf"

PACKAGES=	${CONTENT_ROOT}/packages/${PKGSRC_BRANCH}/x86_64
WRKOBJDIR=	/home/pbulk/build

PREFER_PKGSRC=	yes
EOF

pushd $CONTENT_ROOT
[[ -d pkgsrc ]] ||
  git clone ${PKGSRC_REPO}

pushd pkgsrc
git checkout pkgsrc_${PKGSRC_BRANCH}

# Apply patches but verify their checksums first
declare -A patches
patches["mksandbox-1.3.diff"]="a010aeb1ac05474b889e370113f8f0e1" 
patches["pbulk-joyent.diff"]="b87c6d78b116708aae94b1a92bf13e86" 
for patch_file in "${!patches[@]}"
do
  [[ -f .${patch_file}.done ]] && continue  # Skip if already applied
  curl -Os http://www.netbsd.org/~jperkin/${patch_file}
  md5sum $patch_file | grep ^${patches["$patch_file"]}' ' >/dev/null ||
    ( echo error checksum mismatch ; exit 1 )
  patch -p0 -N -s -r- -i $patch_file 2>&1 >/dev/null 
  mv $patch_file .${patch_file}.done
done

if [[ ! -d /opt/${PROVIDER_DIR}pbulk ]]
then
  pushd bootstrap
  ./bootstrap --abi=64 --prefix=${PBULK_PATH} \
    --mk-fragment=${CONTENT_ROOT}/mk/mk-pbulk.conf \
    --prefer-pkgsrc yes
  ./cleanup
  popd
fi

PATH=${PBULK_PATH}/sbin:${PBULK_PATH}/bin:$PATH
for pkg in pkgtools/pbulk pkgtools/mksandbox
do
  pushd $pkg
  CFLAGS=-Wno-unused-result bmake package-install
  popd
done

id pbulk || 
  ( groupadd pbulk && useradd -g pbulk -c 'pkgsrc pbulk user' -m -s /bin/bash pbulk )

## Update shell path if profile.d is used
if [[ -d /etc/profile.d ]]
then
  cat >/etc/profile.d/pkgsrc-pbulk.sh <<EOF
PATH=${PBULK_PATH}/sbin:${PBULK_PATH}/bin:\$PATH
export PATH
EOF
else
  cat >>EOF
Remember to update your shell PATH env var to include
${PBULK_PATH}/sbin and ${PBULK_PATH}/bin
EOF
fi

# Setup chroot
[[ -d ${CHROOT_PATH} ]] ||
  mkdir ${CHROOT_PATH}

cat >${CONTENT_ROOT}/scripts/mksandbox <<EOF
#!/bin/sh

chrootdir=\$1; shift

while true
do
	# XXX: limited_list builds can recreate chroots too fast.
	if [ -d \${chrootdir} ]; then
		echo "Chroot \${chrootdir} exists, retrying in 10 seconds or ^C to quit"
		sleep 10
	else
		break
	fi
done

${PBULK_PATH}/sbin/mksandbox --without-pkgsrc \\
  --rodirs=${PBULK_PATH} --rwdirs=${CONTENT_ROOT} \${chrootdir} >/dev/null 2>&1
mkdir -p \${chrootdir}/home/pbulk
chown pbulk:pbulk \${chrootdir}/home/pbulk
EOF

cat >${CONTENT_ROOT}/scripts/rmsandbox <<EOF
#!/bin/sh

chrootdir=\`echo \$1 | sed -e 's,/\$,,'\`; shift

if [ -d \${chrootdir} ]; then
	#
	# Try a few times to unmount the sandbox, just in case there are any
	# lingering processes holding mounts open.
	#
	for retry in 1 2 3
	do
		\${chrootdir}/sandbox umount >/dev/null 2>&1
		mounts=\`mount -v | grep "\${chrootdir}/"\`
		if [ -z "\${mounts}" ]; then
			rm -rf \${chrootdir}
			break
		else
			sleep 5
		fi
	done
fi
EOF

chmod u+x ${CONTENT_ROOT}/scripts/{rm,mk}sandbox

[[ -d ${CHROOT_PATH}/build-bootstrap ]] ||
  ${CONTENT_ROOT}/scripts/mksandbox ${CHROOT_PATH}/build-bootstrap

