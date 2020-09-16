#!/bin/bash
# set -x
# This script will write and make a package for post installation on macOS install that re-enroll the device into jamf
# This leverages the start OS isntall in macOS 10.13.4+ on APFS volumes. 
# (APFS supported on macOS 10.14+ with all storage types)
#
# Contents/Resources/startosinstall --installpackage
#
# Requirements:
# An Enrollment Invitation must be configured for multiple uses 
# or you can generate one with the create_computer_invitation.sh
# A workflow that allows you to add the '--installpackage' verb to your 'startosinstall' commmand
# (forked macOSUpgrade Project available here https://github.com/cubandave/macOSUpgrade)
#
# Enrollment functions stolen/borrowed/inspired by 
# https://github.com/jamf/autoenroll
#
# packaging scripts inspired by 
# https://techion.com.au/blog/2014/8/17/creating-os-x-package-files-pkg-in-terminal
# 
# Written by: David Ramirez | cubandave
#
######## UserOptions ########
# Set this to a static policy to change it by parameters to enroll into different environments
invitationConfig="$5"
if [[ -z "$jamfPolicy2CreateInvitation" ]] ; then
	##add your own invitation iD here if you want this to be hardcoded
	##add your own event name here if you want this to be hardcoded
	invitationConfig=""
fi
identifierTag="com.github.cubandave"

title="macOS Wipe and Re-enrollment"

# Make sure to set your own Salt & K
function DecryptString() {
	# Usage: ~$ DecryptString "Encrypted String"
	local SALT=""
	local K=""
	echo "${1}" | /usr/bin/openssl enc -aes256 -d -a -A -S "$SALT" -k "$K"
}

icon="/Applications/System Preferences.app/Contents/Resources/PrefApp.icns"

##This is the custom event name used to run the macOS updgrade 
macOSUpgradePolicyEventName="$9"
if [[ -z "$macOSUpgradePolicyEventName" ]] ;then
	##add your own event name here if you want this to be hardcoded
	macOSUpgradePolicyEventName=""
fi


######## Static Var ########
jamfBinary="/usr/local/jamf/bin/jamf"
jHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper" 


######## paramters ########
jamfURLs="$4"
invitationConfig="$5"
DEPcheckUserName_Encrypted="$6"
DEPcheckUserPass_Encrypted="$7"


##Options for computer name handling for re-enroll workflows
##Use this to control the way that re-enrollment to your jamf Pro server is done
##Requires macOS Installer 10.13.4 or later
##NOTE: To Default to assigning no computer after the wipe put nothing in here
##(ask) - Use jamfHelper to ask the user what to do with the computer name 
##(keepname) - Default to automatically preserve computer name 
##(prename) - Default to automatically asking for a new computer name 
##(splashbuddy) - Add this to the parameter setting to automatically create a ComputerName.txt and .SplashBuddyFormDone 
##For more information please see the project
##https://github.com/cubandave/re-enroll-mac-into-jamf-after-wipe
##make variable lower case
reEnrollmentMethodChecks=$(echo "$8" | tr '[:upper:]' '[:lower:]')

# for Debug and misc testing
# jamfURLs=""
# invitationConfig="1"
# DEPcheckUserName_Encrypted=""
# DEPcheckUserPass_Encrypted=""
# jssURL2Check1=""
# jssURL2Check2=""
# jssURL2Check3=""
# depAssigned=true
# reEnrollmentMethodChecks=$(echo "ask" | tr '[:upper:]' '[:lower:]')

##########################################################################################
##								Pre Processing of Variables								##
##########################################################################################

IFS=";"
set -- "$jamfURLs" 
# This works because i'm setting the seperator
# shellcheck disable=SC2206
# shellcheck disable=SC2048
declare -a jamfURLs=($*)
target_jssURL=$(echo "${jamfURLs[0]}" | tr '[:upper:]' '[:lower:]')
unset IFS

if [[ "$invitationConfig" =~ ^-?[0-9]+$ ]] ;then
	echo Enrollment is set to a static invitation code
	invitationCode="$invitationConfig"
else
	echo Enrollment is set to generate an invitation code.
	jamfPolicy2CreateInvitation="$invitationConfig"
fi


if [[ -z "$target_jssURL" ]] ; then
	/bin/echo "no JSS URL Will not create PKG"
	exit 1
fi

# Decrypt the user name and password
if [[ "$DEPcheckUserName_Encrypted" ]] ;then 
	DEPcheckUserName="$(DecryptString "$DEPcheckUserName_Encrypted")"
fi

if [[ "$DEPcheckUserPass_Encrypted" ]] ;then 
	DEPcheckUserPass="$(DecryptString "$DEPcheckUserPass_Encrypted")"
fi

##Get Current User
currentUser=$( /usr/bin/stat -f %Su /dev/console )

# Name of the package.
NAME="enroll-macos-to-jamf-pro"
# Package version number.
VERSION="1.0"

IDENTIFIER="$identifierTag.$NAME"
scriptsPath="/usr/local/libexc/AutoEnroll"
PKGBuildPath="/tmp/$NAME"


# Enable this to do local debugging 
# if [[ ! -d "$scriptsPath" ]] ; then
# 	/bin/mkdir -p "$scriptsPath"
# fi

/bin/rm -rf "$PKGBuildPath"

# make folder for the package building
if [[ ! -d "$PKGBuildPath" ]] ; then
	/bin/mkdir -p "$PKGBuildPath"
fi

if [[ ! -d "$PKGBuildPath"/scripts ]] ; then
	/bin/mkdir -p "$PKGBuildPath/scripts"
fi

# if [[ ! -d "$PKGBuildPath/files" ]] ; then
	/bin/mkdir -p "$PKGBuildPath/files"
	/bin/mkdir -p "$PKGBuildPath/files/usr/local/libexc/AutoEnroll"
	/bin/mkdir -p "$PKGBuildPath/files/Library/LaunchDaemons/"
	/bin/mkdir -p "$PKGBuildPath/files/Library/LaunchAgents/"
# fi

if [[ ! -d "$PKGBuildPath/compiled" ]] ; then
	/bin/mkdir -p "$PKGBuildPath/compiled"
fi


enrollLaunchDaemonPlist="/Library/LaunchDaemons/$IDENTIFIER.enroll.plist"
afterActionLaunchDaemonPlist="/Library/LaunchDaemons/$IDENTIFIER.afterloginaction.plist"
afterActionLaunchAgentPlist="/Library/LaunchAgents/$IDENTIFIER.afterloginaction.login.plist"
enrollScriptName="$NAME.sh"
afterloginactionScriptName="$NAME.afterloginaction.sh"

##########################################################################################
##										Functions									##
##########################################################################################

triggerNgo ()
{
	$jamfBinary policy -forceNoRecon -trigger "$1" &
}

fn_askWhatToDoForComputerName () {

	keepMessage="Do you want to KEEP the computer name after erasing? 

Current Computer Name: $currentComputerName

To rename click 'Other'.

"

	renameMessage="Do you want to RENAME the computer name after erasing? 

Current Computer Name: $currentComputerName

To not assign any name click 'No Name'.

"


	toKeepOrNotToKeep=$( "$jHelper" -windowType hud -icon "$icon" -heading "Computer Name Setting" -description "$keepMessage" -button1 "Keep" -button2 "Other" -defaultButton 1 -timeout 300 )
	if [[ "$toKeepOrNotToKeep" = 0 ]]; then
		keep=true
	elif [[ "$toKeepOrNotToKeep" = 2 ]] || [[ "$toKeepOrNotToKeep" = 239 ]] ; then
		toRenameOrNotToRename=$( "$jHelper" -windowType hud -icon "$icon" -heading "Computer Name Setting" -description "$renameMessage" -button2 "Rename" -button1 "No Name" -timeout 300 )
		if [[ "$toRenameOrNotToRename" = 2 ]]; then
		prename=true
		fi
	fi

}

fn_askforNewComputerName () {

	newComputerName=$( sudo -u "$currentUser" /usr/bin/osascript -e 'display dialog "Please enter the new computer name" default answer "" with title "Set New Computer Name" with text buttons {"Cancel","OK"} default button 2' -e 'text returned of result' )
}


fn_Process_reEnrollmentMethodChecks () {
	##check for and set the parameters for re enrollment 
	if [[ "$reEnrollmentMethodChecks" ]] ; then

		##clear any previous checks
		/bin/rm /private/tmp/reEnrollmentMethod*

		if [[ "$reEnrollmentMethodChecks" == *"ask"* ]]; then ask=true ; fi
		if [[ "$reEnrollmentMethodChecks" == *"keep"* ]]; then keep=true ; fi
		if [[ "$reEnrollmentMethodChecks" == *"prename"* ]]; then prename=true ; fi
		if [[ "$reEnrollmentMethodChecks" == *"splashbuddy"* ]]; then splashbuddy=true ; fi
	fi
}


fn_createAutoEnrollPackage () {
	# Once installed the identifier is used as the filename for a receipt files in /var/db/receipts/.
	

	# The location to copy the contents of files.
	INSTALL_LOCATION="/"


	# Remove any unwanted .DS_Store files.
	/usr/bin/find "$PKGBuildPath"/files -name '*.DS_Store' -type f -delete

	# Set full read, write, execute permissions for owner and just read and execute permissions for group and other.
	/bin/chmod -R 755 "$PKGBuildPath"/files

	# Remove any extended attributes (ACEs).
	/usr/bin/xattr -rc "$PKGBuildPath"/files

	# Build package.
	/usr/bin/pkgbuild \
		--root "$PKGBuildPath"/files \
		--install-location "$INSTALL_LOCATION" \
		--scripts "$PKGBuildPath"/scripts \
		--identifier "$IDENTIFIER" \
		--version "$VERSION" \
		"$PKGBuildPath/compiled/$NAME-$VERSION.pkg"

	/usr/bin/productbuild --package "$PKGBuildPath/compiled/$NAME-$VERSION.pkg" "$PKGBuildPath/compiled/$NAME-$VERSION-productbuild.pkg"
}


fn_createFullPostInstallScript () {

	##Have to put the shbang line at beginning otherwise PackageKit Hates It
	cat >> "$PKGBuildPath/scripts/postinstall" <<ENDFullPostInstallScript 
#!/bin/bash

	# clear place holder file -mostly here for testing 
	/bin/rm /private/tmp/uaMDMdone

	# Path to LaunchDaemons & Agents.

	enrollLaunchDaemonPlist="/Library/LaunchDaemons/$IDENTIFIER.enroll.plist"
	afterActionLaunchDaemonPlist="/Library/LaunchDaemons/$IDENTIFIER.afterloginaction.plist"
	afterActionLaunchAgentPlist="/Library/LaunchAgents/$IDENTIFIER.afterloginaction.login.plist"

	# Load the new LaunchDaemons.
	/bin/launchctl unload "$enrollLaunchDaemonPlist"
	/bin/launchctl load "$enrollLaunchDaemonPlist"

	/bin/launchctl unload "$afterActionLaunchDaemonPlist"
	/bin/launchctl load "$afterActionLaunchDaemonPlist"

	# Check LaunchDaemons are loaded.
	STATUSenroll=\$( /bin/launchctl list | /usr/bin/grep "$IDENTIFIER.enroll" | /usr/bin/awk '{print \$3}' )
	STATUSafteraction=\$( /bin/launchctl list | /usr/bin/grep "$IDENTIFIER.afterloginaction" | /usr/bin/awk '{print \$3}' )

	if [ "\$STATUSenroll" = "$IDENTIFIER.enroll" ]
	then
			/bin/echo Success LaunchDaemon loaded.
	else
			/bin/echo Error LaunchDaemon not loaded.
			error=true
	fi  

	if [ "\$STATUSafteraction" = "$IDENTIFIER.afterloginaction" ]
	then
			/bin/echo Success LaunchDaemon loaded.
	else
			/bin/echo Error LaunchDaemon not loaded.
			error=true
	fi  

	if [[ \$error == true ]]; then
		exit 1
	else 
		exit 0
	fi
ENDFullPostInstallScript
}


fn_createAfterActionsOnlyPostInstallScript () {

	##Have to put the shbang line at beginning otherwise PackageKit Hates It
	cat >> "$PKGBuildPath/scripts/postinstall" <<ENDAfterActionsOnlyPostInstallScript
#!/bin/bash

	# clear place holder file -mostly here for testing 
	/bin/rm /private/tmp/uaMDMdone

	# Path to LaunchDaemons & Agents.

	afterActionLaunchDaemonPlist="/Library/LaunchDaemons/$IDENTIFIER.afterloginaction.plist"
	afterActionLaunchAgentPlist="/Library/LaunchAgents/$IDENTIFIER.afterloginaction.login.plist"

	# Load the new LaunchDaemons.
	/bin/launchctl unload "$afterActionLaunchDaemonPlist"
	/bin/launchctl load "$afterActionLaunchDaemonPlist"

	# Check LaunchDaemons are loaded.
	STATUSafteraction=\$( /bin/launchctl list | /usr/bin/grep "$IDENTIFIER.afterloginaction" | /usr/bin/awk '{print \$3}' )


	if [ "\$STATUSafteraction" = "$IDENTIFIER.afterloginaction" ]
	then
			/bin/echo Success LaunchDaemon loaded.
	else
			/bin/echo Error LaunchDaemon not loaded.
			error=true
	fi  

	if [[ \$error == true ]]; then
		exit 1
	else 
		exit 0
	fi
ENDAfterActionsOnlyPostInstallScript
}


fn_create_enrollLaunchDaemonPlist () {
	# Write LaunchDaemon plist file.
	
	cat >> "$PKGBuildPath/files/$enrollLaunchDaemonPlist" <<ENDenrollLaunchDaemonPlist
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
		<key>Label</key>
		<string>$IDENTIFIER.enroll</string>
		<key>ProgramArguments</key>
		<array>
			<string>/bin/bash</string>
			<string>$scriptsPath/$enrollScriptName</string>
		</array>
		<key>RunAtLoad</key>
		<true/>
		<key>StartInterval</key>
		<integer>60</integer>
	</dict>
	</plist>
ENDenrollLaunchDaemonPlist

}


fn_create_afterActionLaunchAgentPlist () {
	cat >> "$PKGBuildPath/files/$afterActionLaunchAgentPlist" <<ENDafterActionLaunchAgentPlist
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
	<key>Label</key>
	<string>$IDENTIFIER.afterloginaction.login</string>
	<key>RunAtLoad</key>
	<true/>
	<key>ProgramArguments</key>
	<array>
	<string>/bin/bash</string>
	<string>-c</string>
	<string>while [[ \$( /usr/bin/profiles status -type enrollment ) == *"MDM enrollment: No"* ]] && [[ \$( /usr/bin/profiles status -type enrollment ) == *"Enrolled via DEP: No"* ]] ; do sleep 1 ; done ; if [[ \$(/usr/bin/profiles status -type enrollment ) == *"MDM enrollment: Yes"* ]] && [[ \$( /usr/bin/profiles status -type enrollment ) != *"User Approved"* ]]  ; then if [[ -a \$( /usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path) ]] ; then /usr/bin/open -b com.jamfsoftware.selfservice.mac ; else /usr/bin/open /System/Library/PreferencePanes/Profiles.prefPane ; fi ; fi ; /usr/bin/touch /private/tmp/uaMDMdone \
	</string>
	</array>
	</dict>
	</plist>
ENDafterActionLaunchAgentPlist
}

fn_Create_afterActionLaunchDaemonPlist () {
	# /bin/echo \"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
	cat >> "$PKGBuildPath/files/$afterActionLaunchDaemonPlist" <<ENDafterActionLaunchDaemonPlist
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
	<key>Label</key>
	<string>$IDENTIFIER.afterloginaction</string>
	<key>WatchPaths</key>
		<array>
		   <string>/private/tmp/</string>
		</array>
	<key>ProgramArguments</key>
	<array>
	<string>/bin/bash</string>
	<string>-c</string>
	<string>if [[ -f /private/tmp/uaMDMdone ]] ; then /bin/bash "$scriptsPath/$afterloginactionScriptName" ; fi; \
	</string>
	</array>
	</dict>
	</plist>
ENDafterActionLaunchDaemonPlist
}


fn_createEnrollLaunchDaemonScript () {


	# /bin/echo "#!/bin/bash
	cat >> "$PKGBuildPath/files/usr/local/libexc/AutoEnroll/$enrollScriptName" <<ENDEnrollLaunchDaemonScript
	#!/bin/bash
	
	target_jssURL="$target_jssURL"
	URL2jamfBin="\$target_jssURL/bin/jamf"

	folderCheck() {
		folderList=( /private/var/client /private/var/client/receipts /private/var/client/downloads /private/var/client/pkg )

		for folder in \${folderList[@]} ; do

			if [[ ! -d "\$folder" ]]
				then /bin/mkdir -p "\$folder"
				else /bin/echo "folder exists"
			fi
		done
	}

	jssConnectionTest() {

		jssTest=\$( /usr/bin/curl -k -I "\$target_jssURL"/JSSResource/computers/id/1 | grep 'HTTP/1.1 401' )
		
		if [[ "\$jssTest" ]]
		then /bin/echo "we can connect to the JSS"
	  else /bin/echo "JSS is not reachable...exiting"
			 exit 0
	  fi
	}

	jamfEnroll() {

		# if [[ -f /private/var/client/downloads/jamf.gz ]]
		if [[ -f /private/var/client/downloads/jamf ]]
			then /bin/echo "looks good"
		else /bin/echo "failed to /usr/bin/curl down binary"
			/usr/bin/touch /private/var/client/receipts/clientfailed.txt
			exit 0
		fi
		/bin/chmod +x /private/var/client/downloads/jamf

			# now test it 
			testBinary=\$( /private/var/client/downloads/jamf help 2>&1 > /dev/null ; /bin/echo \$? )
			if [[ "\$testBinary" == "0" ]]
				then /bin/echo "test good, we can move it"
	  		else /bin/echo "something went wrong, marking failed"
				 exit
		fi

	   	# now back up the old JAMF.keychain for those just incase moments
		mv /Library/Application\ Support/JAMF/JAMF.keychain /private/var/client/JAMF.keychain.old 

		# now we need to move the binary, apply proper permissions/ownership into place and enroll the client
		/bin/mkdir -p /usr/local/jamf/bin /usr/local/bin
		mv /private/var/client/downloads/jamf /usr/local/jamf/bin
		ln -s "$jamfBinary" /usr/local/bin
		chown "$jamfBinary"

		"$jamfBinary" createConf -k -url "\$target_jssURL"

		"$jamfBinary" enroll -invitation $invitationCode

	}

	downloadBinary() {

		if [[  -f /private/var/client/downloads/jamf ]] ; then
			/bin/echo previous dowload exists deleting
			/bin/rm /private/var/client/downloads/jamf
		fi
		
		# get the current binary from the JSS
		/usr/bin/curl -ks "\$URL2jamfBin" -o /private/var/client/downloads/jamf

		# if [[ ! -f /private/var/client/downloads/jamf.gz ]]
		if [[ ! -f /private/var/client/downloads/jamf ]]
		
			then /bin/echo "download failed, exiting..."
				/usr/bin/touch /private/var/client/receipts/clientfailed.txt
				exit 1
		fi

	}

	jamfCheck() {

	"$jamfBinary" policy -event testClient

	/bin/sleep 5 # give it 5 seconds to do it's thing

	if [[ -e /private/var/client/receipts/clientresult.txt ]]
	  then /bin/echo "policy created file, we are good"
		/bin/echo "removing dummy receipt for next run"
		/bin/rm /private/var/client/receipts/clientresult.txt
		/bin/rm /private/var/client/receipts/clientfailed.txt
		# exit 0
	  else /bin/echo "policy failed, could not run"
		/usr/bin/touch /private/var/client/receipts/clientfailed.txt
	fi

	}

	fn_destroyTheDaemon () {
		/bin/rm "$enrollLaunchDaemonPlist"
		/bin/launchctl remove "$IDENTIFIER.enroll"
	}

	fn_destroyTheEnrollmentScript () {
		/bin/rm "$scriptsPath/$enrollScriptName"
	}

	folderCheck
	jssConnectionTest
	jamfCheck

	if [[ -e /private/var/client/receipts/clientfailed.txt ]]
		then downloadBinary
			jamfEnroll
		else /bin/echo "no failure found, exiting"

			fn_destroyTheEnrollmentScript
			fn_destroyTheDaemon
			exit 0
	fi
ENDEnrollLaunchDaemonScript
}

fn_createAfterActionLaunchDaemonScript () {


	# /bin/echo "#!/bin/bash
	cat >> "$PKGBuildPath/files/usr/local/libexc/AutoEnroll/$afterloginactionScriptName" <<ENDAfterActionLaunchDaemonScript
	#!/bin/bash
	# New version Thanks to travis-ci
	
	target_jssURL="$target_jssURL"
	nameOfComputer="$nameOfComputer"
	splashbuddy="$splashbuddy"

	loggedInUser=\$( /usr/bin/stat -f%Su /dev/console)

	fn_check4UAMDM () {
		selfServiceAppPath=\$( /usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path)
		if [[ -a "\$selfServiceAppPath" ]] ; then
			/usr/bin/sudo -u \$loggedInUser -H /usr/bin/open -b com.jamfsoftware.selfservice.mac &
		else
			/usr/bin/sudo -u \$loggedInUser -H /usr/bin/open /System/Library/PreferencePanes/Profiles.prefPane &
		fi
	}

	fn_setComputerNameIfNeeded () {
		if [[ \$nameOfComputer ]] ; then 
			"$jamfBinary" setComputerName -name "$nameOfComputer"
		fi
	}

	fn_setSplashBuddyFileIfNeeded () {
		if [[ \$splashbuddy ]] && [[ \$nameOfComputer ]] ; then 
			if [[ ! -d /Users/\$loggedInUser/Library/Containers/io.fti.SplashBuddy/Data/Library ]] ; then
				/usr/bin/sudo -u \$loggedInUser -H /bin/mkdir -p /Users/\$loggedInUser/Library/Containers/io.fti.SplashBuddy/Data/Library
			fi

			/usr/bin/sudo -u \$loggedInUser -H /bin/echo "$nameOfComputer" > /Users/\$loggedInUser/Library/Containers/io.fti.SplashBuddy/Data/computerName.txt 
			/usr/bin/sudo -u \$loggedInUser -H /usr/bin/touch /Users/\$loggedInUser/Library/Containers/io.fti.SplashBuddy/Data/Library/.SplashBuddyFormDone 
		fi
	}

	fn_destroyTheAfterActionDaemon () {
		/bin/rm "$afterActionLaunchDaemonPlist"
		/bin/launchctl remove "$IDENTIFIER.afterloginaction"
	}

	fn_destroyTheAfterActionAgent () {
		/bin/rm "$afterActionLaunchAgentPlist"
		/bin/launchctl unload "$afterActionLaunchAgentPlist"
	}

	fn_destroyTheAfterActionScript () {
		/bin/rm "$scriptsPath/$afterloginactionScriptName"
	}


	# fn_check4UAMDM
	fn_setComputerNameIfNeeded
	fn_setSplashBuddyFileIfNeeded

	# clean up
	/bin/rm /private/tmp/uaMDMdone

	fn_destroyTheAfterActionScript
	fn_destroyTheAfterActionAgent
	fn_destroyTheAfterActionDaemon

	exit 0
ENDAfterActionLaunchDaemonScript
}

fn_setScriptPermissions () {
	/bin/chmod -R 755 "$PKGBuildPath/files/usr/local/libexc/AutoEnroll/"
}


fn_setLaunchDPermissions () {
	/bin/chmod -R 644 "$PKGBuildPath/files/Library/"
}

fn_setPostInstallScriptPermissions () {
	/bin/chmod 777 "$PKGBuildPath/scripts/postinstall"
}



fn_check4_or_createinvitation () {
	if [[ -z "$invitationCode" ]] && [[ "$jamfPolicy2CreateInvitation" ]] ; then
		

		jamfResult=$( "$jamfBinary" policy -event "$jamfPolicy2CreateInvitation" )

		if [[ -z "$jamfResult" ]]; then
			/bin/echo "failed to get invitationCode"
			exit 1
		elif [[ "$jamfResult" == *"Error: "* ]] ; then failed2GetCode=true 
		elif [[ "$jamfResult" == *"Error running script: return code was"* ]] ; then failed2GetCode=true 
		elif [[ "$jamfResult" == *"-:10"* ]] ; then failed2GetCode=true  
		elif [[ "$jamfResult" == *"failed"* ]] ; then failed2GetCode=true ; else
			invitationCode=$( /bin/echo "$jamfResult" | /usr/bin/grep "Script result" | /usr/bin/awk -F ': ' '{ print $2}' )
		fi
	elif [[ -z "$invitationCode" ]] && [[ -z "$jamfPolicy2CreateInvitation" ]]; then
		#statements
		failed2GetCode=true
		/bin/echo "No invitation code method is setup"
		/bin/echo "failed to get invitationCode"
	fi

	if [[ "$failed2GetCode" == true ]] ; then  

	"$jHelper" -windowType hud -title "$title" -icon "$icon" -heading "Re-enrollment Preparation Failed" -description "We were unable to prepare your computer for re-enrollment.

	Failed to generate invitationCode for the re-enrollment package." -iconSize 100 -button1 "OK" -defaultButton 1 &
	exit 1
	fi
}

fn_DEPChecker () {
	currentSerialNumber=$( /usr/sbin/system_profiler SPHardwareDataType | /usr/bin/awk '/Serial/ {print $4}' )

	function jsonValue() {
		KEY=$1
		num=$2
		# shellcheck disable=SC2086
		# shellcheck disable=SC2048
		awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/'$KEY'\042/){print $(i+1)}}}' | tr -d '"' | sed -n ${num}p
	}

	for jss_url_2Check in "${jamfURLs[@]}" ; do
		serialNumber=""
		base64Auth=$( /bin/echo -n "$DEPcheckUserName:$DEPcheckUserPass" | /usr/bin/base64 )


		# Get the Authorization Bearer Token
		getTokenResult=$( /usr/bin/curl --request POST \
			-s \
			--url "$jss_url_2Check/uapi/auth/tokens" \
			--header 'Accept: application/json' \
			--header "Authorization: Basic $base64Auth" \
			--header 'cache-control: no-cache' )

		bearerToken=$( /bin/echo "$getTokenResult" | jsonValue token 1 )
		deviceEnrollmentResult=$( /usr/bin/curl --request GET \
			-s \
			--url "$jss_url_2Check/uapi/v1/device-enrollment" \
			--header 'Accept: application/json' \
			--header "Authorization: Bearer $bearerToken" \
			--header 'cache-control: no-cache' )


		deviceEnrollmentIds=( "$(/bin/echo "$deviceEnrollmentResult" | /usr/bin/grep -v "serverUuid" | jsonValue "id")" )

		# Go through each Device Enrollment and check all the devices inside for a match
		for enrollmentId in "${deviceEnrollmentIds[@]}" ; do
			enrollmentIdDevicesData="/tmp/enrollmentIdDevicesData"
			/usr/bin/curl --request GET \
				-s \
				--url "$jss_url_2Check/uapi/v1/device-enrollment/$enrollmentId/devices" \
				--header 'Accept: application/json' \
				--header "Authorization: Bearer $bearerToken" \
				--header 'cache-control: no-cache' > "$enrollmentIdDevicesData"

			# Using cat so it can read long output
			# Only look for 'profileStatus : PUSHED' OR 'profileStatus : ASSIGNED'
			serialNumber+=$( /usr/bin/grep -B 6 "PUSHED" "$enrollmentIdDevicesData" | jsonValue "serialNumber" )
			serialNumber+=$( /usr/bin/grep -B 6 "ASSIGNED" "$enrollmentIdDevicesData" | jsonValue "serialNumber" )

			# clear the file for the next pull
			/bin/rm "$enrollmentIdDevicesData"
		done

		# If the Serial Number is found the mark it as found
		if [[ "$serialNumber" == *"$currentSerialNumber"* ]] && [[ $depAssigned != true ]] ; then
			/bin/echo "Serial number $currentSerialNumber is DEP assigned to $jss_url_2Check"
			depAssigned=true
			assignedJSS="$jss_url_2Check"
		elif [[ "$serialNumber" == *"$currentSerialNumber"* ]] && [[ "$assignedJSS" != "$jss_url_2Check" ]] ; then
			mulitpleJamfServerDetectedwithDEP=true
			/bin/echo "Serial number $currentSerialNumber is DEP assigned to $jss_url_2Check"
		fi
	done
}

# DEP Check work flow to check if the device is DEP activates
if [[ "$DEPcheckUserName" ]] && [[ "$DEPcheckUserName" ]] ; then
	fn_DEPChecker

	# Error Checking
	if [[ "$depAssigned" = true ]] && [[ "$target_jssURL" != *"$assignedJSS"* ]] && [[ "$mulitpleJamfServerDetectedwithDEP" != true ]] ; then
		"$jHelper" -windowType hud -title "$title" -icon "$icon" -heading "Re-enrollment Preparation Failed" -description "We were unable to prepare your computer for re-enrollment.

		The Mac is assigned for Device Enrollment to a different Jamf Pro Server in Apple Business Manager. The assigned JSS is 
		$assignedJSS." -iconSize 100 -button1 "OK" -defaultButton 1

		/bin/echo "Error: DEP Crossover, the computer is not assigned to the same JSS as the desired target Jamf Pro server."
		/bin/echo "target_jssURL is $target_jssURL."
		/bin/echo "assignedJSS is $assignedJSS."
		/bin/echo "This will cause it to fail to run your desired test."
		/bin/echo "Please double check the policy you are running,"
		/bin/echo "or change the assignment of device and wait for a sync (about 5 mins)."
		exit 1
	elif [[ "$mulitpleJamfServerDetectedwithDEP" = true ]] ; then
		"$jHelper" -windowType hud -title "$title" -icon "$icon" -heading "Re-enrollment Preparation Failed" -description "We were unable to prepare your computer for re-enrollment.

		The Mac is assigned for Device Enrollment across multiple Jamf Pro Servers." -iconSize 100 -button1 "OK" -defaultButton 1

		/bin/echo "Error: DEP multiple Jamf Pro servers have this computer in ASSIGNED or PUSHED status."
		/bin/echo "This could cause it to fail to run your desired test."
		/bin/echo "Please double check the pre-enrollment settings and wait for a sync (about 5 mins)."
		/bin/echo "Also check Apple Business/School Manager to assure that the intended target is selected."
		exit 1
	fi
fi

####### First Magic ######

##This is the beginning of the re-enroll work-flow to handle the computer name
if [[ "$reEnrollmentMethodChecks" ]]  ; then
	fn_Process_reEnrollmentMethodChecks

	/bin/echo "Script is configured for re-enrollment."

	## if re-enrollment is enabled to ask what to do about the name
	currentComputerName=$( /usr/sbin/scutil --get ComputerName )

	if [[ $ask = true ]] && [[ ${currentUser} != "root" ]] ; then
		/bin/echo "Asking what to do about the computer name."
		fn_askWhatToDoForComputerName
	elif [[ $ask = true ]] && [[ ${currentUser} = "root" ]]; then
		#statements
		keep=true
		/bin/echo "The computer is at the login window. Defaulting to preserving the computer name."
	fi

	if [[ $keep = true ]]; then
		/bin/echo "Keeping the current computer name."
		newComputerName="$currentComputerName"
	fi 

	if [[ $prename = true ]]; then
		/bin/echo "Assigning a new computer name."
		fn_askforNewComputerName
	fi 

	# Computer name is assigned after eraseinstall
	if [[ "$newComputerName" ]]; then
		/bin/echo "Assigned computer name after eraseinstall: $newComputerName"
	nameOfComputer="$newComputerName"
	fi 
fi # re-enrollment and erase install - prep for naming the computer after eraseinstall stage



################# MAGIC HAPPENS HERE ###############

fn_createAfterActionLaunchDaemonScript
	
if [[ "$depAssigned" = true ]]; then
	/bin/echo "Device is DEP assigned to the target_jssURL $target_jssURL."
	/bin/echo "Therefore skipping the jamf auto enrollment parts."
	
	fn_createAfterActionsOnlyPostInstallScript

	fn_create_afterActionLaunchAgentPlist
	fn_Create_afterActionLaunchDaemonPlist
else # device is not DEP Assigned

	fn_check4_or_createinvitation
	fn_createEnrollLaunchDaemonScript

	fn_createFullPostInstallScript

	fn_create_afterActionLaunchAgentPlist
	fn_Create_afterActionLaunchDaemonPlist
	fn_create_enrollLaunchDaemonPlist
fi

fn_setPostInstallScriptPermissions
fn_setLaunchDPermissions
fn_setScriptPermissions

fn_createAutoEnrollPackage

if [[ -f "$PKGBuildPath/compiled/$NAME-$VERSION-productbuild.pkg" ]] ;then
	if [[ "$macOSUpgradePolicyEventName" ]] ; then
		triggerNgo "$macOSUpgradePolicyEventName"
	fi
	exit 0
else
	"$jHelper" -windowType hud -title "$title" -icon "$icon" -heading "Re-enrollment Preparation Failed" -description "We were unable to prepare your computer for re-enrollment.

Re-enrollment package could not be found." -iconSize 100 -button1 "OK" -defaultButton 1
	/bin/echo/ "The package is not present"
	exit 1
fi
