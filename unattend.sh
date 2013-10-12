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

SCRIPT="$0"

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

General Options:
    -install=DISK-FILE
        install OS to DISK-FILE
    -disk-format=FORMAT
        specify format of DISK-FILE, default vmdk
    -disk-size=SIZE
        specify system disk size, default 25GB
    -mem-size=SIZE
        specify memory size in MB when installing system, default 1024
EOF
    exit 2
}

fatal() {
    echo "$@" 1>&2
    exit 1
}

extract_embedded_file() {
    local tag=$1 out="$2" lns lne
    lns=$(grep -E -n "^<<TAG$tag" "$SCRIPT" | cut -d : -f 1)
    lne=$(grep -E -n "^TAG$tag" "$SCRIPT" | cut -d : -f 1)
    [ -n "$lns" -a -n "$lne" ] || fatal "TAG not found $tag"
    lns=$((lns+1))
    lne=$(($lne-$lns))
    tail -n +$lns "$SCRIPT" | head -n $lne
}

random_passwd() {
    < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo
}

install_prepare() {
    local osdisk="$1"

    [ -z "$QEMU" ] && QEMU=kvm
    if [ -z "$QEMU_IMG" ]; then
        if [ "${QEMU/kvm/}"=="$QEMU" ]; then
            QEMU_IMG=qemu-img
        else
            QEMU_IMG=kvm-img
        fi
    fi

    local disk_size="$OPT_DISK_SIZE"
    [ -z "$disk_size" ] && disk_size=25G
    local disk_fmt="$OPT_DISK_FORMAT"
    [ -z "$disk_fmt" ] && disk_fmt=vmdk

    "$QEMU_IMG" create -f $disk_fmt "$osdisk" $disk_size
}

install_windows_image() {
    local srciso="$1" unattendiso="$2" osdisk="$3"

    install_prepare "$osdisk"

    local mem_size="$OPT_MEM_SIZE"
    [ -z "$mem_size" ] && mem_size=1024

    "$QEMU" -m $mem_size -boot order=cd,once=d -net none \
            -drive file="$osdisk",media=disk,cache=unsafe \
            -drive file="$srciso",media=cdrom,cache=unsafe \
            -drive file="$unattendiso",media=cdrom,cache=unsafe \
            $QEMU_OPTS
}

install_windows() {
    local srciso="$1" imgname="$2"
    [ -f "$srciso" ] || usage
    [ -n "$imgname" ] || usage

    local outiso="$OPT_OUT"
    [ -z "$outiso" ] && outiso=unattend.iso

    local tmpdir="/tmp/autounattend-$$"
    [ -d "$tmpdir" ] && rm -fr "$tmpdir"
    mkdir -p "$tmpdir"
    extract_embedded_file AUTOUNATTEND  | sed "s/!IMAGENAME!/$imgname/g" | sed "s/!PASSWORD!/$(random_passwd)/g" >"$tmpdir/autounattend.xml"
    extract_embedded_file DEPLOYXML     | sed "s/!PASSWORD!/$(random_passwd)/g" >"$tmpdir/deploy.xml"
    extract_embedded_file DEPLOYCMD     >"$tmpdir/deploy.cmd"
    extract_embedded_file OOBEXML       >"$tmpdir/oobe.xml"
    mkisofs -J -R -o "$outiso" "$tmpdir"
    rm -fr "$tmpdir"

    if [ -n "$OPT_INSTALL" ]; then
        install_windows_image "$srciso" "$outiso" "$OPT_INSTALL"
    fi
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
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%SystemRoot%\system32\sysprep\sysprep /generalize /oobe /shutdown /unattend:%ConfigSetRoot%\deploy.xml</CommandLine>
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

<<TAGDEPLOYXML
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
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
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>%SystemRoot\ConfigSetRoot\deploy.cmd</CommandLine>
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
TAGDEPLOYXML

<<TAGDEPLOYCMD
FOR %%d in (D: E: F: G: H: I: J: K: L: M: N: O: P: Q: R: S: T:) DO (
    IF EXIST %%d\autodeploy.cmd (
        %%d\autodeploy.cmd
    )
)
%SystemRoot%\system32\sysprep\sysprep /generalize /oobe /reboot /unattend:%SystemRoot%\ConfigSetRoot\oobe.xml
TAGDEPLOYCMD

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
