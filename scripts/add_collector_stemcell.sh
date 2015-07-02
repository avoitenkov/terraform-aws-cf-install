#!/bin/bash

set -e -x

function disable {
  if [ -e $1 ]
  then
    mv $1 $1.back
    ln -s /bin/true $1
  fi
}

function enable {
  if [ -L $1 ]
  then
    mv $1.back $1
  else
    # No longer a symbolic link, must have been overwritten
    rm -f $1.back
  fi
}

function parse_yaml () {
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s=\"%s\"\n", vn, $2, $3);
      }
   }'
   return 0
}

function run_in_chroot {
  local chroot=$1
  local script=$2

  # Disable daemon startup
  disable $chroot/sbin/initctl
  disable $chroot/usr/sbin/invoke-rc.d

  unshare -m $SHELL <<EOS
    mkdir -p $chroot/dev
    mount -n --bind /dev $chroot/dev
    mount -n --bind /dev/pts $chroot/dev/pts

    mkdir -p $chroot/proc
    mount -n --bind /proc $chroot/proc

    chroot $chroot env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin http_proxy=${http_proxy:-} sudo bash -e -c "$script"
EOS

  # Enable daemon startup
  enable $chroot/sbin/initctl
  enable $chroot/usr/sbin/invoke-rc.d
}

function print_usage {
    test -z "$1" || echo "ERROR: $1"
    echo USAGE:
    echo "$SCRIPTNAME <stemcell_path> <new_stemcell_path> <tenant_id> <fe_url> <server_tag>"
}

SCRIPTNAME=$(basename $0)

test $(whoami) == root || { print_usage "run with sudo"; exit 1; }

STEMCELL=$1
STEM_OUTPUT=$2
APPFIRST_TENANT_ID=$3
APPFIRST_FRONTEND_URL=$4
APPFIRST_SERVER_TAGS=$5

test -z $STEM_OUTPUT && { print_usage "missing output stemcell filename"; exit 1; }
test -z $STEMCELL && { print_usage "missing stemcell filename"; exit 1; }
test -z $APPFIRST_TENANT_ID && { print_usage "missing output stemcell filename"; exit 1; }
test -z $APPFIRST_FRONTEND_URL && { print_usage "missing output stemcell filename"; exit 1; }
test -z $APPFIRST_SERVER_TAGS && { print_usage "missing server_tags"; exit 1; }
test -f $STEMCELL || { print_usage "$STEMCELL not found"; exit 2; }

if [[ "$STEMCELL" != /* ]]; then
    # Relative path
    STEMCELL=$(pwd)/$STEMCELL
fi

BUILD_DIR=$(mktemp -d -t stemcellXXXXXXXXX)

mkdir -p $BUILD_DIR/{mnt,stemcell}

MNT_STEM=$BUILD_DIR/mnt
STEM_TMP=$BUILD_DIR/stemcell

pushd $STEM_TMP

echo "Extract stemcell"
tar xvf $STEMCELL
echo "Extract image"
tar xvf image

echo "Mount image"
losetup /dev/loop0 root.img
kpartx -a /dev/loop0
mount /dev/mapper/loop0p1 $MNT_STEM

echo "Download AppFirst package"
downloaded_file="af_package.deb"
url="https://www.dropbox.com/s/6xnf7v0wscc1v5t/new.distrodeb64.deb"
wget $url -qO $MNT_STEM/$downloaded_file

echo "Install AppFirst package"
run_in_chroot $MNT_STEM "dpkg -i $downloaded_file"
run_in_chroot $MNT_STEM "chown root:root /etc/init.d/afcollector"
run_in_chroot $MNT_STEM "/usr/sbin/update-rc.d afcollector defaults 15 85"

ls -la $MNT_STEM/etc/init.d/

rm $MNT_STEM/$downloaded_file

echo "<configuration>" | tee $MNT_STEM/etc/AppFirst
echo "URLfront $APPFIRST_FRONTEND_URL" | tee --append $MNT_STEM/etc/AppFirst
echo "Tenant $APPFIRST_TENANT_ID" | tee --append $MNT_STEM/etc/AppFirst
echo "</configuration>" | tee --append $MNT_STEM/etc/AppFirst

echo "server_tags: [$APPFIRST_SERVER_TAGS]" | tee --append $MNT_STEM/etc/AppFirst.init
rm -rfv $MNT_STEM/etc/init/afcollector.conf
rm -rfv $MNT_STEM/var/log/*collector*
grep -Rli collector $MNT_STEM/var/log/* | xargs rm -fv

echo "Unmount image"
umount $MNT_STEM
dmsetup remove /dev/mapper/loop0p1
losetup -d /dev/loop0

rm image
echo "Compress image"
tar -czf image root.img

echo "Change SHA1"
SHA1SUM=`sha1sum image | awk '{print $1}'`
sed -i "/sha1:/c\sha1: $SHA1SUM" stemcell.MF

# Run in subprocess to not pollute enviroment with YAML reading
(
  eval $(parse_yaml stemcell.MF "") 
  sed -i -e "s/name: $name/name: collector_$name/g" stemcell.MF
)
popd # $STEM_TMP

tar -czf $BUILD_DIR/output_tmp.tgz -C $STEM_TMP image stemcell.MF apply_spec.yml

mv $BUILD_DIR/output_tmp.tgz $STEM_OUTPUT

rm -Rf $BUILD_DIR
