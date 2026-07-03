#!/bin/sh
# NOTE: becomes .tmp_update/miyoomini.sh

PLATFORM="miyoomini"
SDCARD_PATH="/mnt/SDCARD"
UPDATE_PATH="$SDCARD_PATH/MinUI.zip"
SYSTEM_PATH="$SDCARD_PATH/.system"

# --- LODOR CLOCK RESTORE (task #147): forward-only boot restore from datetime.txt ---
# RTC-less boards boot at epoch. Restore the last persisted wall time so every early
# timestamp (logs, saves, playtime) is sane before any network. FORWARD-ONLY: a stored
# time in the past NEVER moves the clock backward - NTP (set_clock) stays the only
# authority allowed to correct backward.
LODOR_DT="$SDCARD_PATH/.userdata/shared/datetime.txt"
if [ -f "$LODOR_DT" ]; then
	_lodor_stored="$(head -n1 "$LODOR_DT" 2>/dev/null)"
	_lodor_now="$(date +'%F %T' 2>/dev/null)"
	_lodor_s="$(printf '%s' "$_lodor_stored" | tr -cd '0-9')"
	_lodor_n="$(printf '%s' "$_lodor_now" | tr -cd '0-9')"
	if [ "${#_lodor_s}" -eq 14 ] && [ "${#_lodor_n}" -eq 14 ] && [ "$_lodor_s" != "$_lodor_n" ]; then
		# equal-length digit strings: lexicographic order == chronological order
		if [ "$(printf '%s\n%s\n' "$_lodor_s" "$_lodor_n" | sort | head -n1)" = "$_lodor_n" ]; then
			if date -s "$_lodor_stored" >/dev/null 2>&1; then
				# best-effort hwclock write-back where an RTC node exists
				if command -v hwclock >/dev/null 2>&1 && { [ -e /dev/rtc0 ] || [ -e /dev/rtc ]; }; then
					hwclock -w >/dev/null 2>&1
				fi
			fi
		fi
	fi
fi
# --- END LODOR CLOCK RESTORE ---

CPU_PATH=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo performance > "$CPU_PATH"

# install/update
if [ -f "$UPDATE_PATH" ]; then 
	cd $(dirname "$0")/$PLATFORM
	
	# init backlight
	echo 0 > /sys/class/pwm/pwmchip0/export
	echo 800 > /sys/class/pwm/pwmchip0/pwm0/period
	echo 50 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle
	echo 1 > /sys/class/pwm/pwmchip0/pwm0/enable

	# init lcd
	cat /proc/ls
	sleep 1
	export LCD_INIT=1

	if [ -d "$SYSTEM_PATH" ]; then
		./show.elf ./updating.png
	else
		./show.elf ./installing.png
	fi
	
	mv $SDCARD_PATH/.tmp_update $SDCARD_PATH/.tmp_update-old
	unzip -o "$UPDATE_PATH" -d "$SDCARD_PATH"
	rm -f "$UPDATE_PATH"
	rm -rf $SDCARD_PATH/.tmp_update-old
	
	# the updated system finishes the install/update
	$SYSTEM_PATH/$PLATFORM/bin/install.sh
fi

# or launch (and keep launched)
LAUNCH_PATH="$SYSTEM_PATH/$PLATFORM/paks/MinUI.pak/launch.sh"
while [ -f "$LAUNCH_PATH" ] ; do
	"$LAUNCH_PATH"
done

reboot # under no circumstances should stock be allowed to touch this card
