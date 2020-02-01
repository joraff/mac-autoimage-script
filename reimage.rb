#!/usr/bin/ruby

require "rubygems"
require "json"
require "socket"
require "highline/import"
require "uri"

#######################
# Set some of your customizations below
#######################

# Display name of the temporary storage partition
TEMP_NAME = "TEMP"

# Size of the temporary storage partition
TEMP_SIZE = 30 #GB

# Filename of the default OS X torrent
MAC_DEFAULT_TORRENT = "default.torrent"

# URL prefix of the default OS X torrent
MAC_URI_PREFIX = "https://torrent.host:54321/torrents/mac/"

# Filename of the default windows torrent
WIN_DEFAULT_TORRENT = "windows.torrent"

# URL prefix of the default windows torrent
WIN_URI_PREFIX = MAC_URI_PREFIX

# Path to the mounted temporary storage partition
TEMP_PATH = "/Volumes/#{TEMP_NAME}"

# Partition identifier for the temporary storage partition
TEMP_PARTITION = `diskutil info #{TEMP_PATH} | grep "Device Node:" | awk '{print $3}'`.strip


# ANSI escape sequence cheats - makes this type of interaction code much easier to read
# http://en.wikipedia.org/wiki/ANSI_escape_code

# Move the cursor the the beginning of the previous line
ANSI_PREV_LINE = "\e[1F"
# Move the cursor the the beginning of the next line
ANSI_NEXT_LINE = "\e[1E"
# Clear the current line
ANSI_CLEAR_LINE = "\e[2K"
# Clear and move the cursor to the beginning of the current line
ANSI_RESET = "\r" + ANSI_CLEAR_LINE

# Move the cursor forward n columns on the current line
# ==== Attributes
# * +n+ - Number of cells to move
def ANSI_FWD(n)
  "\e[#{n}C"
end

# Move the cursor backwards n columns on the current line
# ==== Attributes
# * +n+ - Number of cells to move
def ANSI_BACK(n)
  "\e[#{n}D"
end

# Characters to use in moving progress bar
PROGRESS_CHARS = ['|', '\\', '"', '/']



# Main logic method. This is a technique to allow all your other methods to be defined
# without either using a module or separate required file.
# This method should only be invoked once at the end of the file.

def main
  
  # Verify that the current machine is in our inventory.
  # This also creates the instance variable @w which contains information about this workstation.
  verify_managed_machine

  # Customize these workflow options to match your environment

  puts "Imaging Workflow choices:"
  puts "1. Dual-Boot Partitioning, Restore Mac, Restore Windows"
  puts "2. Dual-Boot Partitioning, Restore Mac only"
  puts "3. Single-Boot Partitioning, Restore Mac only"
  puts "4. Single-Boot Partitioning, Restore Windows only"
  puts "5. Do not modify partition table, Restore Mac only"
  puts "6. Do not modify partition table, Restore Windows only"
  puts "7. Create Windows partition by shrinking Mac, Restore Windows only"
  puts "8. Install MBR and Windows bootloaders only."
  puts "9. Secure erase whole disk"

  # Set the default choice (either from the inventory server, or 3)
  default = ( !@w.nil? && @w['workflow']) ? @w['workflow'] : 3
  choice = nil


  print "\n\n"
  prompt = "Choice: "
  print prompt
  
  (1..30).each do |i| 
    print "#{ANSI_PREV_LINE}#{ANSI_CLEAR_LINE}(Default option #{default.to_s} will be chosen automatically in #{30-i} seconds)#{ANSI_NEXT_LINE}\e[#{prompt.length}C"
    $stdout.flush
    sleep 1
    Thread.new do
      choice = STDIN.gets.strip
    end
    if choice
      break
    end
  end

  print "#{ANSI_CLEAR_LINE}"     # clear current line

  choice = (choice || default).to_s
  puts "You chose: #{choice}"

  $stdout.flush
  
  # Disk identifier of the local disk
  LOCAL_DISK_ID = get_local_disk_id
  
  case choice
  when "1" # dual-boot, restore mac & win
  	disable_hid
  	disable_sleep
  	partition("dual")
  	start_bt
  	id = add_torrent("os x")
  	track_torrent_progress(id)
  	restore_mac(id)
  	erase_temp
  	id = add_torrent("windows")
  	track_torrent_progress(id)
  	restore_win(id)
  	create_share
  	bless_reboot

  when "2" # dual-boot, restore mac only
  	disable_hid
  	disable_sleep
  	partition("dual")
  	start_bt
  	id = add_torrent("os x")
  	track_torrent_progress(id)
  	restore_mac(id)
  	create_share
  	bless_reboot
  
  when "3" # single-boot mac
  	disable_hid
  	disable_sleep
  	partition("single")
  	start_bt
  	id = add_torrent("os x")
  	track_torrent_progress(id)
  	restore_mac(id)
  	create_share
  	bless_reboot

  when "4" # single-boot win
  	# TODO

  when "5" # restore mac only
  	disable_hid
  	disable_sleep
  	erase_temp
  	start_bt
  	id = add_torrent("os x")
  	track_torrent_progress(id)
  	restore_mac(id)
  	create_share
  	bless_reboot
  
  when "6" # restore win only
  	disable_hid
  	disable_sleep
  	erase_temp
  	start_bt
  	id = add_torrent("windows")
  	track_torrent_progress(id)
  	restore_win(id)
  	create_share
  	bless_reboot
   
  when "7" # add & restore windows
  	disable_hid
  	disable_sleep
  	resize("dual")
  	start_bt
  	id = add_torrent("windows")
  	track_torrent_progress(id)
  	restore_win(id)
  	create_share
  	bless_reboot("win")
    
  when "8" # windows MBR and bootloaders only
  	restore_win_no_image
  	`diskutil mountDisk disk0`
  	bless_reboot("win")
    
  when "9"
  	erase_disk
  	shutdown
    
  else
    puts "No matching choice for #{choice}"
    exit
  end
end


#############
# Disables the mouse and keyboard on the workstation 
# ==== Flaw: 
# If the user unplugs and replugs the mouse and/or keyboard, the kernel automatically reloads this kext.
#############

def disable_hid
  `kextunload -b com.apple.iokit.IOHIDFamily`
  `/Applications/Utilities/updateDialog.app/Contents/MacOS/applet`
end


#############
# Disables the computer and display from sleeping during the imaging process
# ==== Flaw:
# Won't set them back after imaging. Use MCX or munki to customize these, dummy.
#############

def disable_sleep
  `pmset -a displaysleep 0`
  `pmset -a sleep 0`
end


#############
# Checks our inventory database to verify that this workstation is one of our managed workstation
# Sends the en0 hardware address to a remote TCP service, expects a JSON hash with computer info in return
# Allows non-managed workstations to proceed, but only after a due warning and user confirmation.
#############

def verify_managed_machine
  host = "inventory.host"
  port = 4525   # Old port serving Mashalled data is 4524

  # Make sure our inventory server is reachable
  unless `/usr/sbin/scutil -r #{host}`.strip == "Reachable"
    verify_continue("Inventory server is not responding")
  end
  
  # Get the en0 or en1 hardware address.
  # TODO: Might think about changing this to serial number. MAC addresses can change
  hw = `/sbin/ifconfig en0`.strip
  if hw.include? "does not exist" #no en0, try en1?
    hw = `/sbin/ifconfig en1`.strip
  end
  hw = hw.match(/ether (.*)/)[1].strip.upcase
      
  # Open the socket to the service on #{host}
  s = TCPSocket.new(host, port)
  if s
    begin
      s.puts hw # give the socket stream our mac address
      reply = s.recv(4096)
      unless reply.empty?
        @w = JSON.parse(reply)
      else
        raise "Empty response from the inventory server. Perhaps this computer isn't in the DB?"
      end
    rescue
      verify_continue($!)
    end
  
    s.close
    puts "Verified as a managed machine. Proceeding with imaging."
    return
  else
    verify_continue("Unexpected response from inventory server")
  end
end


#############
# Make the user verify that they want to procede if the computer is not in our inventory
#
# ==== Parameters
# * +error+ - Error/Warning message to display along with data loss warning/prompt
#############

def verify_continue(error="")
  
  prompt = <<-eop
    Warning: #{error}

    This computer could not be verified as a computer operated by Baylor University's Student Technology Services deparment. Choosing to continuing could result in irreversible data loss!!!!
    If you are sure you want to continue, please type 'continue':
  eop
  
  if prompt_user(prompt) == "continue" OR "'continue'"
    return
  else
    puts "This computer will restart in 30 seconds"
    sleep 30
    `shutdown -r now`
  end
end


#############
# Partition the disk
# ==== Parameters
# * +type+ - Type of partition workflow to use. Can be one of:
# 
#   * +single+ - One operating system partition (default)
#   * +dual+ - Two operating system partitions of equal sizes
#
#############

def partition(type="single")
  
  size, units = get_disk_info(LOCAL_DISK_ID)
  
  puts "#{diskID} size is #{size}#{units}"
  
  usableSize = size - TEMP_SIZE
  puts "Remaining size after temporary partition is #{usableSize}#{units}"
  
  if type == "dual"
    partitionSize = usableSize/2.floor
    puts "Number of system partitions: 2"
    puts "Size of system partitions: #{partitionSize}#{units}"
    puts "Partitioning..."
    puts `diskutil partitionDisk /dev/#{diskID} 3 GPTFormat \
          jhfs+ "Macintosh HD" #{partitionSize}G \
          hfs+ "#{TEMP_NAME}" #{TEMP_SIZE}G \
          "MS-DOS FAT32" "WINDOWS" #{partitionSize}G`
    unless $? == 0
      puts "ERROR: Disk failed to partition!"
      exit
    end
  else
    partitionSize = usableSize
    puts "Number of system partitions: 1"
    puts "Size of system partitions: #{partitionSize}#{units}"
    puts "Partitioning..."
    puts `diskutil partitionDisk /dev/#{diskID} 2 GPTFormat \
          jhfs+ "Macintosh HD" #{partitionSize}G \
          hfs+ "#{TEMP_NAME}" #{TEMP_SIZE}G`
    unless $? == 0
      puts "ERROR: Disk failed to partition!"
      exit
    end
    
    unless File.writable?("#{TEMP_PATH}")
      puts "ERROR: #{TEMP_PATH} failed to mount or is not writable."
      exit
    end
  end
end


#############
# Resizes the main partition and adds the temp and windows partition
# ==== Parameters
# * +type+ - Type of resize action to take. Can be one of:
# 
#   * +single+ - Non-destructively expands disk<em>n</em>s2 to use all available disk space, minus the temporary partition. Warning: all other partitions will be erased.
#   * +dual+ - Non-destructively decreases the size of disk<em>n</em>s2 to make room for the windows OS partition. Assumes there was no other partition after disk<em>n</em>s2.
#
#############

def resize(type="dual")
  
  size, units = get_disk_info(LOCAL_DISK_ID)
  
  puts "#{diskID} size is #{size}#{units}"

  usableSize = size - TEMP_SIZE
  puts "Remaining size after temporary partition is #{usableSize}#{units}"
  
  if type == "dual"
    partitionSize = usableSize/2.floor
    puts "Number of system partitions: 2"
    puts "Size of system partitions: #{partitionSize}#{units}"
    
    last_device = `diskutil list disk0 | tail -n 1 | sed -e 's/^.*[MGT]B *//'`
    puts "Merging partitions disk0s2 to #{last_device}"
    system("diskutil mergePartitions JHFS+ 'Macintosh HD' disk0s2 #{last_device}")
    
    puts "Shrinking disk0s2 to make space for windows partition."
    system("diskutil resizeVolume /dev/disk0s2 #{partitionSize}G \
    2 \
    hfs+ 'TEMP' #{TEMP_SIZE}G \
    'MS-DOS FAT32' 'WINDOWS' #{partitionSize-1}G")
  
    unless $? == 0
      puts "ERROR: Disk failed to resize!"
      exit
    end
  else
    partitionSize = usableSize
    puts "Number of system partitions: 1"
    puts "Size of system partitions: #{partitionSize}#{units}"
    puts "Resizing #{LOCAL_DISK_ID}s2 partition to be #{partitionSize}#{units}.."
    system("diskutil resizeVolume /dev/#{LOCAL_DISK_ID}s2 #{partitionSize}G \
    1 \
    hfs+ 'TEMP' #{TEMP_SIZE}G")
    
    unless $? == 0
      puts "ERROR: Disk failed to partition!"
      exit
    end
  
    unless File.writable?("#{TEMP_PATH}")
      puts "ERROR: #{TEMP_PATH} failed to mount or is not writable."
      exit
    end
  end
end


#############
# Returns the local disk ID, which is initially assumed to be disk0.
# If disk0 is actually the netbooted disk, this will prompt the user for the local disk ID
#############

def get_local_disk_id
  # Sometimes the netbooted disk gets assigned disk0. Most of the time, this means no local disk was detected
  diskID = "disk0"
  if `mount | grep " / " | grep -o 'disk[0-9]'`.strip == diskID
    # Uh-oh, the netboot image was disk0. Not good. We're in trouble here.
    puts "Cannot automatically determine the disk identifier for the local disk. Is a physical disk installed? Is it working?"
    puts "Try running diskutil list to see what's recognized."
    diskID = prompt_for_local_disk_id
  end
  
  # Does that diskID really exist?
  while system("diskutil info #{diskID} > /dev/null")
    puts "#{diskID} does not appear to be a valid disk identifier."
    diskID = prompt_for_local_disk_id
  end
end


#############
# Returns the size and units of a particular disk
# ==== Parameters
# * +diskID+ - the disk identifier (in disk<em>n</em> format) of the disk in question
#############

def get_disk_info(diskID)
  # Sometimes the netbooted disk gets assigned disk0. Most of the time, this means no local disk was detected
  diskID = "disk0"
  if `mount | grep " / " | grep -o 'disk[0-9]'`.strip == diskID
    # Uh-oh, the netboot image was disk0. Not good. We're in trouble here.
    puts "Cannot automatically determine the disk identifier for the local disk. Is a physical disk installed? Is it working?"
    puts "Try running diskutil list to see what's recognized."
    diskID = prompt_for_local_disk_id
  end
  
  # Does that diskID really exist?
  while system("diskutil info #{diskID} > /dev/null")
    puts "#{diskID} does not appear to be a valid disk identifier."
    diskID = prompt_for_local_disk_id
  end

  # Get the total size and the units of the target disk 
  size, units = `diskutil info #{diskID} | grep "Total Size" | awk '{print $3,$4}'`.split
  size = size.to_i
  if units == "TB"
    # Starting with 10.6, size units are Base10, not Base12. We need to convert this to GB correctly
    size *= 1000
    units = "GB"
  end
  
  return diskID, size, units
end


#############
# Prompts the user for manual input
# ==== Parameters
# * +prompt_text+ - Text to prompt the user to answer.
# * +timeout+ (optional)- a timeout value (in seconds) after which the default value will be chosen
# * +default_value+ (optional) - The default value that is shown and chosen by the user entering nothing or ob a timeout
#
# Note: a timeout value will be ignored if a default value is omitted
#############

def prompt_user(prompt_text, timeout=0, default_value="")
  choice = nil

  print "\n\n"
  print prompt_text
  
  # Don't timeout if no default value was given
  timeout = 0 if default_value.empty? 
    
  if timeout > 0
    (0..(timeout*10)).each do |i| 
      Thread.new do
        choice = STDIN.gets.strip
      end
      break if choice
      print "#{ANSI_PREV_LINE}\e[0K(Default option #{default_value.to_s} will be chosen automatically in #{timeout-i/10} seconds)#{ANSI_NEXT_LINE}#{ANSI_FWD(prompt_text.length)}"
      $stdout.flush
      sleep(0.1)
    end
    
    # Fill in the prompt with the default value if we timed out
    print "#{ANSI_PREV_LINE}\e[#{prompt_text.length}C" unless choice.nil?
    choice = default_value if choice.nil? or choice.empty?
    puts choice
  else
    choice = STDIN.gets.strip
  end
  
  return choice
end



#############
# Will prompt the user for the local disk identifier
# ==== Parameters:
# * +diskID+ - the disk identifier (in disk<em>n</em> format) of the disk in question
#
# ==== Returns:
# A string of the local disk identifier
#############

def prompt_for_local_disk_id
  prompt_user("What is the disk identifier for the internal hard drive?", 30, "disk0")
end


#############
# Starts the bittorrent daemon in the background
#############

def start_bt
  unless system("killall -0 transmission-daemon")  
    unless system("transmission-daemon &")
      puts "ERROR: Transmission daemon failed to start!"
      exit
    end
  end
  5.times do
    unless system("transmission-remote -l")
      sleep 2
    else 
      puts "Bittorrent daemon is running."
      `transmission-remote --download-dir "#{TEMP_PATH}"`
      break
    end
  end
end


#############
# Starts downloading the specified torrent
#
# ==== Parameters:
# * +os+ - The operating system to download. Can be one of +os x+ of +windows+.
# ==== Returns:
# A string of the transmission torrent ID for the added torrent
#
#############

def add_torrent(os="os x")
  
  # Set the defaults
  case os
  when "os x"
    print "Adding OS X torrent..."
    torrent_key = "torrent_mac"
    default_torrent = MAC_DEFAULT_TORRENT
    uri_prefix = MAC_URI_PREFIX
  when "windows"
    print "Adding windows torrent..."
    torrent_key = "torrent_win"
    default_torrent = WIN_DEFAULT_TORRENT
    uri_prefix = WIN_URI_PREFIX
  else
    puts "Unknown torrent file specified"
    exit
  end
  
  # Create URL to the torrent file (using value from inventory server or the default)
  torrent_file = ( !@w.nil? && @w[torrent_key]) ? @w[torrent_key] : default_torrent
  url = URI.join(uri_prefix, torrent_file)
  
  # Add the torrent to the daemon
  `transmission-remote --add #{url.to_s}`
  
  # Grab the transmission torrent ID
  id = `transmission-remote -l | grep -i dmg | awk -F' ' '{print $1}'`.strip
  
  # Make sure it started
  `transmission-remote -t #{id} -s`
  
  puts "OS X torrent is added and started. Transmission torrent ID = #{id}"
  return id
end



#############
# Tracks the download progress of a torrent. Displays a progress bar until the torrent has completed downloading.
#
# ==== Parameters:
# * +id+ - The id number of the torrent to follow
#
#############

def track_torrent_progress(id)
  progress = 0
  while progress < 100
    progress = `transmission-remote -t #{id} -i | grep "Percent Done" | awk '{print $3}' | sed -e 's/%//g'`.strip.to_i
    bar = ""
    (0..progress).each do |i|
      if i%10 == 0
        # Display the progress percentage as a number at each 10%
        bar << i.to_s
      elsif i%2 == 0
        # And periods for each successive 2%
        bar << "."
      end
    end

   
    print "#{ANSI_RESET}"
    # Display the progress bar and ASCII spinning beach ball!
    print "Download progress: #{p_bar} #{PROGRESS_CHARS[0]}"
    
    # Rotate the queue of progress spinner characters
    PROGRESS_CHARS[0, 0] = PROGRESS_CHARS.pop

    sleep 1
    $stdout.flush
  end
  
  #print "#{ANSI_RESET}"
  print "Done. Verifying download data..."
  
  # Wait until the %have equals the %verified
  until `transmission-remote -t #{id} -i | grep Have: | sed -e 's/(//g' | awk '{print $2}'` == `transmission-remote -t #{id} -i | grep Have: | sed -e 's/(//g' | awk '{print $4}'`
    sleep 2
  end
  puts "verified."
end


#############
# Restores the OS X partition onto the local disk using +asr+. Always restores to partition 2. Displays the output of +asr+.
#
# ==== Parameters:
# * +id+ - The id number of the OS X torrent
#
#############

def restore_mac(id)
  # Get the path to the downloaded image
  source = `transmission-remote -t #{id} -f | awk NR==1 | cut -f1 -d"("`.strip
  puts "Initiating restore of OS X source onto #{LOCAL_DISK_ID}s2"
  system("asr restore --source '#{TEMP_PATH}/#{source}' --target /dev/#{LOCAL_DISK_ID}s2 --erase --noprompt --verbose")
  unless $? == 0
    puts "ERROR: asr failed to restore the image to disk."
    exit
  end
end


#############
# Restores the windows partition onto the local disk using deploystudio's +ntfsrestore.sh+ script.
# Always restores to partition 4.
# Displays the output of +ntfsrestore.sh+.
#
# ==== Parameters:
# * +id+ - The id number of the windows torrent
#
#############

def restore_win(id)
  # Get the path to the downloaded image folder
  source = `transmission-remote -t #{id} -f | awk NR==1 | cut -f1 -d"("`.strip
  ntfs_file = `ls #{source} | grep .ntfs`
  puts "Restoring windows partition…"
  system("/usr/local/dstools/ntfsrestore.sh #{source}/#{ntfs_file} #{LOCAL_DISK_ID}s4")
  unless $? == 0
    puts "ERROR: ntfsrestore failed to restore the image to disk."
    exit
  end
end


#############
# Installs the MBR and windows bootloader for partition 4.
# Uses a modified version of deploystudio's +ntfsrestore.sh+
#
# This is typically only used if the windows image has been mirrored to disk outside of this netboot.
#############

def restore_win_no_image
  system("/usr/local/dstools/ntfsrestore-setuponly.sh disk0s4")
  unless $? == 0
    puts "ERROR: ntfsrestore failed to install the mbr and bcd to disk."
    exit
  end
end


#############
# Erases the temp partition
#############

def erase_temp
  # Won't be able to unmount the volume if transmission is still seeding the image
  kill_bt
  
  puts "Erasing temporary storage"
  `diskutil eraseVolume hfs+ "#{TEMP_NAME}" /dev/#{TEMP_PARTITION}`
end


#############
# Turns the temp partition into empty FAT32 shared storage partition
#############

def create_share
  puts "Preparing shared storage space"
  
  # Won't be able to unmount the volume if transmission is still seeding the image
  kill_bt
  
  system("diskutil eraseVolume 'MS-DOS FAT32' 'SAVEHERE' /dev/#{TEMP_PARTITION}")
  unless $? == 0
    puts "WARNING: diskutil failed to format #{TEMP_PARTITION} as FAT32"
  end
end


#############
# Stops the bittorrent daemon
#############

def kill_bt
  id = `ps -ax | grep daemon$ | awk -F' ' '{print $1}'`
  puts "Stopping bittorrent daemon with id = #{id}"
  `kill -9 #{id}`
end


#############
# Blesses a volume and reboots the computer
#
# ==== Attributes:
# * +os+ - The operating system to bless. Can be on of +os x+ or +windows+. If not specified, defaults to +os x+.
#############

def bless_reboot(os="os x")
  if(os == "os x")
    puts `bless --device /dev/#{LOCAL_DISK_ID}s2 --setBoot`
  elsif os == "windows"
    puts `bless --device /dev/#{LOCAL_DISK_ID}s4 --setBoot --nextonly --legacy`
  end
  if $? == 0
    `reboot`
  else
    puts "ERROR: failed to bless the #{os} partition!"
    exit
  end
end


#############
# Performs a 1-pass write of zeros the entire local disk.
#
# Displays the progress from +diskutil+.
#############

def erase_disk
  puts "Erasing whole disk at #{LOCAL_DISK_ID}"
  system("diskutil zeroDisk /dev/#{LOCAL_DISK_ID}")
  puts "Finished erasing."
end


#############
# Shuts down the computer
#############

def shutdown
  puts "Shutting down..."
  # puts `shutdown -h now`
end


# Our methods are all defined, kick off the script's main code
main

