#!/bin/bash
# For debug
# set -x
#
#
# This script will make an auto expiring invitation code for macOS Re-enroll workflow
# This leverages Clasic API
# (APFS supported on macOS 10.14+ with all storage types)
#
# Contents/Resources/startosinstall --installpackage
#
# Requirements:
# A Jamf Pro user account with Create access to Computer Enrollment Invitations
#
# Enrollment functions stolen/borrowed/inspired by 
# https://github.com/jamf/autoenroll
# 
# packaging scripts inspired by 
# https://techion.com.au/blog/2014/8/17/creating-os-x-package-files-pkg-in-terminal
# 
# Written by: David Ramirez | cubandave

###################################
#         User Options            #
###################################

# Set to -1 for no site or set to the ID number of the site you want to enroll it
enroll_into_site="-1"

# Set this to true in order for the computer to stay in the orignal site if it already exists
keep_existing_site_membership="false"

# depeding on time zones this gets hairy so i keep it at 2 days
desiredExpirtion_in_secconds="172800"

# Make sure to set your own Salt & K
function DecryptString() {
    # Usage: ~$ DecryptString "Encrypted String"
    local SALT="0a330eef929cf732"
    local K="a480e1672ee3ee3274f5ec1b"
    /bin/echo "${1}" | /usr/bin/openssl enc -aes256 -d -a -A -S "$SALT" -k "$K"
}

#########################################################

jss_url="$4"
jss_user_encrypted="$5"
jss_pass_encrypted="$6"

ssh_username_encrypted="$7"
create_account_if_does_not_exist="$8"
hide_account="$9"
lock_down_ssh="${10}"

# you can use paramter 11 to set a static managment account password
# be set to a static password (MUST BE ENCRYPTED!!!)
mgmtpassword="${11}"
if [[ -z "$mgmtpassword" ]] ; then
  mgmtpassword=$( /usr/bin/openssl rand -hex 12 )
  mgmtpasswordIsSetToRandom=true
fi 

# For Debug & testing
# jss_url="https://cubandave.local:8443"
# jss_user_encrypted="U2FsdGVkX18KMw7vkpz3MtRRgkoDVNSB8aqlFZViR/k="
# jss_pass_encrypted="U2FsdGVkX18KMw7vkpz3MulsfLhGy8WLRLQzH7dyCt0="

# ssh_username_encrypted="U2FsdGVkX18KMw7vkpz3MtRRgkoDVNSB8aqlFZViR/k="
# create_account_if_does_not_exist="true"
# hide_account="false"
# lock_down_ssh="true"
# mgmtpassword="U2FsdGVkX18KMw7vkpz3MulsfLhGy8WLRLQzH7dyCt0="

jss_user=$(DecryptString "$jss_user_encrypted")
jss_pass=$(DecryptString "$jss_pass_encrypted")
ssh_username=$(DecryptString "$ssh_username_encrypted")

# if the new password is an encrypted string then decrypt it
if [[ "$mgmtpasswordIsSetToRandom" != true ]] ; then
  mgmtpassword=$(DecryptString "$mgmtpassword")
fi

################# Functions ###############

fn_calulate_expirationdate () {
  currentDate_epoch=$( /bin/date +%s )
  expiration_date_epoch=$(/bin/echo "$currentDate_epoch" + "$desiredExpirtion_in_secconds" | bc)
  expiration_date=$( /bin/date -jf "%s" "$expiration_date_epoch" +"%Y-%m-%d %H:%M:%S" )
}

fn_generateXMLforInvitaionCode () {
  computer_invitation_XML="<computer_invitation>
  <expiration_date>$expiration_date</expiration_date>
  <ssh_username>$ssh_username</ssh_username>
  <ssh_password>$mgmtpassword</ssh_password>
  <multiple_uses_allowed>true</multiple_uses_allowed>
  <create_account_if_does_not_exist>$create_account_if_does_not_exist</create_account_if_does_not_exist>
  <hide_account>$hide_account</hide_account>
  <lock_down_ssh>$lock_down_ssh</lock_down_ssh>
  <enrolled_into_site>
    <id>$enroll_into_site</id>
  </enrolled_into_site>
  <keep_existing_site_membership>$keep_existing_site_membership</keep_existing_site_membership>
  <site>
    <id>-1</id>
    <name>None</name>
  </site>
  </computer_invitation>"
}

################# MAGIC HAPPENS HERE ###############

fn_calulate_expirationdate

fn_generateXMLforInvitaionCode

invitationResponse="/tmp/invitation.xml"
# send XML to JSS. Invitation code will be in there
fn_uploadXML () {
 /usr/bin/curl -s -k "${jss_url}/JSSResource/computerinvitations/id/0" -u "${jss_user}:${jss_pass}" -H "Content-Type: text/xml" -X POST -d "$computer_invitation_XML" -o "$invitationResponse" 
}


# Check for invitation code and spit it out as a script result to picked up by the PKG tool
if fn_uploadXML && [[ "$( cat "$invitationResponse" )" != *"Status page"* ]] && [[ "$( cat "$invitationResponse" )" != *"html"* ]] ; then
  invitation=$( /bin/echo "$( cat "$invitationResponse" )" | /usr/bin/xmllint --xpath "/computer_invitation/invitation/text()" - )
  /bin/echo "$invitation"
else
  /bin/echo generation of computer_invitation failed
  exit 1
fi
