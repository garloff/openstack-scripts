#!/bin/bash
#
# imgreg.sh
# Shellscript for SCS-compliant image registration
# on OpenStack clouds.
# (c) Kurt Garloff <kurt@garloff.de>, 2018 -- 2026
# SPDX-License-Identifier: Apache-2.0

#set -x
set -e
if test -z "$1"; then echo "Usage imgreg.sh [--otc] [--raw] [--community][--public] [--manager MNTNR] file"; exit 1; fi
export LC_ALL=en_US
#defaults
VISIBILITY=shared
if test "$1" == "--otc"; then shift; OTC=1; fi
if test "$1" == "--raw"; then shift; RAW=1; fi
if test "$1" == "--community"; then shift; VISIBILITY=community; fi
if test "$1" == "--public"; then shift; VISIBILITY=public; fi
if test "$1" == "--manager"; then shift; LOGNAME=$1; shift; fi
MIN_RAM=1024
# MIN_DISK=5
ARCH=x86_64
IMG=$1
IMGNM=$(basename "$1")
IMGFMT="${IMGNM##*.}"
OS_DISTRO=${IMGNM%%-*}
IMGNOEXT="${IMGNM%.*}"
OS_VER="${IMGNOEXT#*-}"
OS_VER="${OS_VER%%-*}"
BUILDDT=$(TZ=UTC stat -c %y "$1")
BUILDDT="${BUILDDT%%.*}"
BUILDDT=${BUILDDT:0:10}
BUILDDT=${BUILDDT:-$(date +%Y-%m-%d)}
IMGINFO=$(qemu-img info "$1")
IMGFMT=$(echo "$IMGINFO" | grep '^file format' | sed 's/^file format: //')
DISKSZ=$(echo "$IMGINFO" | grep '^virtual size' | sed 's/^[^(]*(\([0-9]*\) bytes).*$/\1/')
DISKSZ=$(((DISKSZ+1073741823)/1073741824))

getval()
{
	DESC="$1"; shift
	echo -n "$DESC [$@]: " 1>&2
	read val
	if test -z "$val"; then echo "$@"; else echo "$val"; fi
}

OS_DISTRO=$(getval Distro $OS_DISTRO)
OS_DIST=$(echo $OS_DISTRO | tr A-Z a-z)
case $OS_VER in
	2[0-9]04)
		OS_VER=${OS_VER:0:2}.04;;
esac
OS_VER=$(getval Version $OS_VER)
if test "$OS_DIST" = "windows"; then
	OS_DIST2="${OS_DIST}_${OS_VER%% *}"
	OS_OS="windows"
else
	OS_DIST2="${OS_DIST}"
	OS_OS="linux"
fi
# Special case for capi images
case $IMGNM in
	ubuntu-2[02468]04-kube-v*)
		IMAGE_NAME=ubuntu-capi-image-v${IMGNOEXT##*-v}
		DISKSZ=20
		MIN_RAM=2048;;
	openSUSE*)
		IMAGE_NAME="$OS_DISTRO $OS_VER";;
	*)
		IMAGE_NAME="$(echo ${OS_DISTRO:0:1} | tr a-z A-Z)${OS_DISTRO:1} $OS_VER";;
esac
IMAGE_NAME=$(getval "Image Name" "$IMAGE_NAME")
# OTC extras
if test "$OTC" = "1"; then
	OS_DIST3=$(echo "${OS_DIST:0:1}" | tr a-z A-Z)
	OS_DIST3="${OS_DIST3}${OS_DISTRO:1} $OS_VER 64bit"
	EXTRA="--property __support_kvm=\"true\""
	EXTRA="$(getval 'Extra OTC flags' $EXTRA)"
       	EXTRA2="--property __os_version="
       	EXTRA3="$OS_DIST3"
else
	EXTRA2="--property hw_qemu_guest_agent="
	EXTRA3="yes"
fi
# Lowercase os_distro
OS_DISTRO="$(echo $OS_DISTRO | tr A-Z a-z)"
OS_PURPOSE=generic
DISKSZ=$(getval "Min Disk Size" $DISKSZ)
MIN_RAM=$(getval "Min RAM" $MIN_RAM)
BUILDDT=$(getval "Build Date" "$BUILDDT")
ARCH=$(getval "Architecture" $ARCH)
case $OS_DISTRO in
	# ImgFactory build
	opensuse)
		DEFLT_USER=linux;;
	*)
		DEFLT_USER=$(echo $OS_DISTRO | tr A-Z a-z);;
esac
DEFLT_USER=$(getval "Default User Name" $DEFLT_USER)
case $OS_DISTRO in
	opensuse)
		IMG_DESC=https://kfg-images.obs-website.eu-de.otc.t-systems.com/;
		IMG_SRC="${IMG_DESC}$IMGNM";;
	ubuntu)
		if test "${IMAGE_NAME:0:18}" = "ubuntu-capi-image-"; then
			IMG_DESC=https://github.com/osism/k8s-capi-images
			FNM=${IMGNOEXT##*-v}; FNM=${FNM%.*}
			# https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images/ubuntu-2404-kube-v1.33/ubuntu-2404-kube-v1.33.qcow2
			IMG_SRC=https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images/ubuntu-2404-kube-v$FNM/${IMG##*/}
			OS_PURPOSE=k8snode
		else
			IMG_DESC=https://cloud-images.ubuntu.com/
			case $OS_VER in
				20.04) UBNM=focal;;
				22.04) UBNM=jammy;;
				24.04) UBNM=noble;;
				25.04) UBNM=plucky;;
				26.04) UBNM=resolute;;
				*) UBNM=ANIMAL;;
			esac
			IMG_SRC="$IMG_DESC/releases/$UBNM/release/$IMGNM"
		fi;;
	debian)
		IMG_DESC=https://cloud.debian.org/images/cloud/
		case $OS_VER in
			10) DEBNM=buster;;
			11) DEBNM=bullseye;;
			12) DEBNM=bookworm;;
			13) DEBNM=trixie;;
			*) DEBNM=UNKNOWN;;
		esac
		IMG_SRC="$IMG_DESC/$DEBNM/latest/$IMGNM";;
	alpine)
		IMG_DESC=https://alpinelinux.org/cloud/
		IMG_SRC=https://dl-cdn.alpinelinux.org/alpine/v${OS_VER%.*}/releases/cloud/$IMGNM;;
		#OS_PURPOSE=minimal
	fedora)
		IMG_DESC=https://fedoraproject.org/cloud/download
		IMG_SRC=https://download.fedoraproject.org/pub/fedora/linux/releases/$OS_VER/Cloud/x86_64/images/$IMGNM;;
	*)
		IMG_DESC=none
		IMG_SRC=unknown;;
	# TODO: Arch https://wiki.archlinux.org/title/Arch_Linux_on_a_VPS#Official_Arch_Linux_cloud_image
	# TODO:	Gentoo https://www.gentoo.org/news/2025/02/20/gentoo-qcow2-images.html
esac
IMG_DESC=$(getval "Image description" $IMG_DESC)
IMG_SRC=$(getval "Image download link" $IMG_SRC)
# SCS image spec
echo "Image management and update policy"
MGD_BY="managed_by_$LOGNAME"
MGD_BY=$(getval "Managed by" "$MGD_BY")
if test "${MGD_BY#managed_by_}" = "$MGD_BY"; then MGD_BY="managed_by_$MGD_BY"; fi
RPL_FREQ="never"
PROV_UNTIL="$((${BUILDDT:0:4}+1))${BUILDDT:4:10}" # Don't do this in a leap year on Feb 29
UUID_VAL="$PROV_UNTIL"
RPL_FREQ=$(getval "Replace Frequency" $RPL_FREQ)
PROV_UNTIL=$(getval "Provided until" $PROV_UNTIL)
UUID_VAL=$(getval "UUID validity until" $UUID_VAL)

if test "$RAW" = 1 -a "$IMGFMT" != "raw"; then
	qemu-img convert "$IMG" -O raw -S 4k "$IMGNM.raw"
	if test "$?" = 0; then
		IMGFMT=raw
		IMG="$IMGNM.raw"
	else
		echo "WARNING: Conversion to RAW image failed"
		unset RAW
	fi
else
	unset RAW
fi

echo -e "openstack image create --disk-format $IMGFMT --min-disk $DISKSZ --min-ram $MIN_RAM \\
	--$VISIBILITY --file \"$IMG\" \\
	--property image_build_date=\"$BUILDDT\" --property image_original_user=\"$DEFLT_USER\" \\
	--property architecture=\"$ARCH\" --property os_distro=\"$OS_DISTRO\" \\
	--property os_version=\"$OS_VER\" --property os_purpose=\"$OS_PURPOSE\" \\
	--property hw_disk_bus=scsi --property hw_scsi_model=virtio-scsi \\
	--property hw_rng_model=virtio --property hw_vif_multiqueue_enabled=true \\
	--property image_source=\"$IMG_SRC\" \\
	--property image_description=$IMG_DESC \\
	--property replace_frequency=$RPL_FREQ --property provided_until=$PROV_UNTIL \\
	--property uuid_validity=$UUID_VAL \\
	--tag $MGD_BY --tag os:$OS_DIST --tag path:os:$OS_OS:$OS_DIST2 \\
	$EXTRA2\"$EXTRA3\" $EXTRA \\
	\"$IMAGE_NAME\""
openstack image create --disk-format $IMGFMT --min-disk $DISKSZ --min-ram $MIN_RAM \
	--$VISIBILITY --file "$IMG" \
	--property image_build_date="$BUILDDT" --property image_original_user="$DEFLT_USER" \
	--property architecture="$ARCH" --property os_distro="$OS_DISTRO" \
	--property os_version="$OS_VER" --property os_purpose="$OS_PURPOSE" \
	--property hw_disk_bus=scsi --property hw_scsi_model=virtio-scsi \
	--property hw_rng_model=virtio --property hw_vif_multiqueue_enabled=true \
	--property image_source="$IMG_SRC" \
	--property image_description=$IMG_DESC \
	--property replace_frequency=$RPL_FREQ --property provided_until=$PROV_UNTIL \
	--property uuid_validity=$UUID_VAL \
	--tag $MGD_BY --tag os:$OS_DIST --tag path:os:$OS_OS:$OS_DIST2 \
	$EXTRA2"$EXTRA3" $EXTRA \
	"$IMAGE_NAME"
if test "$RAW" = 1; then rm "$IMG"; fi
