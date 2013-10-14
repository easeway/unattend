#!/bin/bash

# This tool is used to generate autoattend files
# for installing Windows unattended. It also
# helps to install a base Windows with KVM.
# After the base OS is installed, it is prepared
# for further unattended customization. After next
# reboot, the unattend script will look for
# a "autodeploy.cmd" on root directory from all
# drives (except A:, B:, C:), and finally
# invoke "sysprep /generalize /oobe" to restart
# the machine.

# Copyright 2013 Yisui Hu (easeway@gmail.com), see LICENSE
# git clone https://github.com/easeway/unattend.git

SCRIPT="$0"

[ -z "$QEMU" ] && QEMU=kvm
if [ -z "$QEMU_IMG" ]; then
    if [ "${QEMU/kvm/}"=="$QEMU" ]; then
        QEMU_IMG=qemu-img
    else
        QEMU_IMG=kvm-img
    fi
fi

qemu_img_create() {
    local disk_file="$1" disk_size="$2"
    shift; shift

    local disk_fmt="$OPT_DISK_FORMAT"
    [ -z "$disk_fmt" ] && disk_fmt=vmdk

    "$QEMU_IMG" create -f $disk_fmt "$@" "$disk_file" $disk_size
}

qemu_run() {
    local mem_size="$OPT_MEM_SIZE"
    [ -z "$mem_size" ] && mem_size=1024
    "$QEMU" -m $mem_size -net none "$@" $QEMU_OPTS
}

usage() {
    cat <<EOF
Usage:
    unattend.sh COMMAND options...
COMMAND:
    windows <INSTALL-ISO> <IMAGE-NAME>
        generate ISO image for installing Windows unattended

        INSTALL-ISO Windows installation ISO
        IMAGE-NAME  Windows image name, like "Windows Server 2008 R2 SERVERENTERPRISE"

        Options:
            -out=UNATTEND-ISO
                specify output unattend ISO, or unattend.iso in current directory
            -license=PRODUCT-KEY
                specify product key
            -install=DISK-FILE
                install OS to DISK-FILE
            -disk-format=FORMAT
                specify format of DISK-FILE, default vmdk
            -disk-size=SIZE
                specify system disk size, default 25GB

    deploy <OS-DISK-FILE> DEPLOY-ISO...
        start next phase deployment

        OS-DISK-FILE    system disk created in first phase
        DEPLOY-ISO      ISO images to attach, max 3

        Options:
            -base-disk=BASE-DISK-FILE
                use this option to create a cloned disk instead of modifying
                original disk

    finalize <OS-DISK-FILE>
        finalize the deployment and allow next boot to OOBE

        OS-DISK-FILE    system disk used for deployment

        Options:
            -base-disk=BASE-DISK-FILE
                use this option to create a cloned disk instead of modifying
                original disk

General Options:
    -mem-size=SIZE
        specify memory size in MB when installing system, default 1024
EOF
    exit 2
}

error() {
    echo "$@" 1>&2
    return 1
}

fatal() {
    error "$@"
    exit 1
}

extract_embedded_file() {
    local tag=$1 out="$2" lns lne
    lns=$(grep -E -n "^<<TAG$tag" "$SCRIPT" | cut -d : -f 1)
    lne=$(grep -E -n "^TAG$tag" "$SCRIPT" | cut -d : -f 1)
    if ! [ -n "$lns" -a -n "$lne" ]; then
        error "TAG not found $tag"
        return 1
    fi
    lns=$((lns+1))
    lne=$(($lne-$lns))
    tail -n +$lns "$SCRIPT" | head -n $lne
}

with_tmpdir() {
    local tmpdir="/tmp/autounattend-$$" ret
    [ -d "$tmpdir" ] && rm -fr "$tmpdir"
    mkdir -p "$tmpdir"
    TMPDIR="$tmpdir" "$@"
    ret=$?
    rm -fr "$tmpdir"
    return $ret
}

random_passwd() {
    < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo
}

install_prepare() {
    local osdisk="$1"

    local disk_size="$OPT_DISK_SIZE"
    [ -z "$disk_size" ] && disk_size=25G

    qemu_img_create "$osdisk" $disk_size
}

install_windows_image() {
    local srciso="$1" unattendiso="$2" osdisk="$3"

    install_prepare "$osdisk"

    qemu_run -boot order=cd,once=d \
        -drive file="$osdisk",media=disk,cache=unsafe \
        -drive file="$srciso",media=cdrom,cache=unsafe \
        -drive file="$unattendiso",media=cdrom,cache=unsafe
}

make_autounattend() {
    local imgname="$1" outiso="$2"
    extract_embedded_file AUTOUNATTEND  | sed "s/!IMAGENAME!/$imgname/g" | sed "s/!PASSWORD!/$(random_passwd)/g" >"$TMPDIR/autounattend.xml"
    extract_embedded_file DEPLOYCMD     >"$TMPDIR/deploy.cmd"
    extract_embedded_file FINALIZECMD   >"$TMPDIR/finalize.cmd"
    extract_embedded_file OOBEXML       >"$TMPDIR/oobe.xml"
    mkisofs -J -R -o "$outiso" "$TMPDIR"
}

install_windows() {
    local srciso="$1" imgname="$2"
    [ -f "$srciso" ] || usage
    [ -n "$imgname" ] || usage

    local outiso="$OPT_OUT"
    [ -z "$outiso" ] && outiso=unattend.iso

    with_tmpdir make_autounattend "$imgname" "$outiso"

    if [ -n "$OPT_INSTALL" ]; then
        install_windows_image "$srciso" "$outiso" "$OPT_INSTALL"
    fi
}

cdrom_drives() {
    for iso in "$@"; do
        [ -n "$iso" ] && echo -n "-drive file=$iso,media=cdrom,cache=unsafe "
    done
}

prepare_osdisk() {
    local osdisk="$1"

    if [ -n "$OPT_BASE_DISK" ]; then
        local disk_fmt=$("$QEMU_IMG" info "$OPT_BASE_DISK" | grep -E '^file format:' | sed -r 's/^file format\:\s*(\S+).*$/\1/')
        local disk_size=$("$QEMU_IMG" info "$OPT_BASE_DISK" | grep -E '^virtual size:' | sed -r 's/^virtual size\:\s*(\S+).*$/\1/')
        [ -n "$disk_fmt" -a -n "$disk_size" ] || fatal "Base disk unavailable: $OPT_BASE_DISK"
        [ -z "$OPT_DISK_FORMAT" ] && OPT_DISK_FORMAT=$disk_fmt
        qemu_img_create "$osdisk" $disk_size -b "$OPT_BASE_DISK"
    fi

    [ -f "$osdisk" ] || usage
}

deploy() {
    local osdisk="$1"
    shift

    prepare_osdisk "$osdisk"
    qemu_run -boot order=cd -drive file="$osdisk",media=disk,cache=unsafe $(cdrom_drives "$@")
}

make_finalize_iso() {
    local iso="$1"
    echo '%SystemRoot%\ConfigSetRoot\finalize.cmd' >"$TMPDIR/autodeploy.cmd"
    mkisofs -J -R -o "$iso" "$TMPDIR/autodeploy.cmd"
}

finalize() {
    local osdisk="$1" iso="finalize.iso"

    with_tmpdir make_finalize_iso "$iso"

    prepare_osdisk "$osdisk"
    qemu_run -boot order=c -drive file="$osdisk",media=disk,cache=unsafe -drive file="$iso",media=cdrom
}

COMMAND=""
PARAMS=()

parse_opt() {
    local opt="$1"
    local name=${opt%%=*} val=${opt#*=}
    name=${name//-/_}
    eval OPT_${name^^}='"$val"'
}

push_param() {
    local param="$1"
    local len=${#PARAMS[*]}
    PARAMS[$len]="$param"
}

for opt in "$@"; do
    case $opt in
        -*)
            parse_opt "${opt:1}"
            ;;
        *)
            if [ -z "$COMMAND" ]; then
                COMMAND="$opt"
            else
                push_param "$opt"
            fi
            ;;
    esac
done

case "${COMMAND,,}" in
    windows)
        install_windows "${PARAMS[@]}"
        ;;
    deploy)
        deploy "${PARAMS[@]}"
        ;;
    finalize)
        finalize "${PARAMS[@]}"
        ;;
    *)
        usage
        ;;
esac

exit $?

<<TAGAUTOUNATTEND
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-us</UILanguage>
            </SetupUILanguage>
            <InputLocale>0409:00000409</InputLocale>
            <UILanguage>en-us</UILanguage>
            <UserLocale>en-us</UserLocale>
            <SystemLocale>en-us</SystemLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Extend>true</Extend>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Active>true</Active>
                            <Format>NTFS</Format>
                            <Label>SYSTEM</Label>
                            <Letter>C</Letter>
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                </Disk>
                <WillShowUI>OnError</WillShowUI>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <Credentials />
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/NAME</Key>
                            <Value>!IMAGENAME!</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>1</PartitionID>
                    </InstallTo>
                    <WillShowUI>OnError</WillShowUI>
                </OSImage>
            </ImageInstall>
            <UserData>
                <ProductKey>
                    <WillShowUI>Never</WillShowUI>
                </ProductKey>
                <AcceptEula>true</AcceptEula>
                <Organization>VMware</Organization>
                <FullName>vCHS-Service</FullName>
            </UserData>
            <UseConfigurationSet>true</UseConfigurationSet>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>!PASSWORD!</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>2</LogonCount>
                <Username>Administrator</Username>
            </AutoLogon>
            <ComputerName>*</ComputerName>
            <TimeZone>GMT Standard Time</TimeZone>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>0409:00000409</InputLocale>
            <UILanguage>en-us</UILanguage>
            <UserLocale>en-us</UserLocale>
            <SystemLocale>en-us</SystemLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%ConfigSetRoot%\deploy.cmd init</CommandLine>
                    <Order>1</Order>
                </SynchronousCommand>
            </FirstLogonCommands>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>!PASSWORD!</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
        </component>
    </settings>
</unattend>
TAGAUTOUNATTEND

<<TAGDEPLOYCMD
SETLOCAL
SET DEPLOYED=%1
IF "%DEPLOYED%"=="init" (
    reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /f
    reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v unattend-deploy /t REG_SZ /d "%ConfigSetRoot%\deploy.cmd" /f
)
FOR %%d in (D: E: F: G: H:) DO (
    IF EXIST %%d\autodeploy.cmd (
        SET DEPLOYED=yes
        CALL %%d\autodeploy.cmd
    )
)
IF NOT "%DEPLOYED%"=="" ( shutdown /p ) ELSE CALL %SystemRoot%\ConfigSetRoot\finalize.cmd
TAGDEPLOYCMD

<<TAGFINALIZECMD
%SystemRoot%\system32\sysprep\sysprep /generalize /oobe /shutdown /unattend:%SystemRoot%\ConfigSetRoot\oobe.xml
TAGFINALIZECMD

<<TAGOOBEXML
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>*</ComputerName>
            <TimeZone>GMT Standard Time</TimeZone>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>0409:00000409</InputLocale>
            <UILanguage>en-us</UILanguage>
            <UserLocale>en-us</UserLocale>
            <SystemLocale>en-us</SystemLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
        </component>
    </settings>
</unattend>
TAGOOBEXML
