# encoding: utf-8

# File:
#      modules/BootCommon.ycp
#
# Module:
#      Bootloader installation and configuration
#
# Summary:
#      Data to be shared between common and bootloader-specific parts of
#      bootloader configurator/installator, generic versions of bootloader
#      specific functions
#
# Authors:
#      Jiri Srain <jsrain@suse.cz>
#      Joachim Plack <jplack@suse.de>
#      Olaf Dabrunz <od@suse.de>
#
# $Id$
#

require "tempfile"
require "yaml"
require "bootloader/udev_mapping"

module Yast
  module BootloaderRoutinesLibIfaceInclude
    def initialize_bootloader_routines_lib_iface(_include_target)
      textdomain "bootloader"

      Yast.import "Storage"
      Yast.import "Mode"

      # Loader the library has been initialized to use
      @library_initialized = nil
    end

    STATE_FILE = "/var/lib/YaST2/pbl-state"

    class TmpYAMLFile
      attr_reader :path

      def self.open(data = nil, &block)
        file = new(data)
        block.call(file)
      ensure
        file.unlink if file
      end

      def initialize(data = nil)
        @path = mktemp
        write_data(data) unless data.nil?
      end

      def unlink
        SCR.Execute(Path.new(".target.remove"), path)
      end

      def data
        YAML.load(SCR.Read(Path.new(".target.string"), path))
      end

    private

      def mktemp
        res = SCR.Execute(Path.new(".target.bash_output"),
          "mktemp /tmp/y2yamldata-XXXXXX")
        raise "mktemp failed with error #{res["stderr"]}" if res["exit"] != 0

        res["stdout"].chomp
      end

      def write_data(data)
        SCR.Write(Path.new(".target.string"), path, YAML.dump(data))
      end
    end

    def run_pbl_yaml(*args)
      cmd = "pbl-yaml --state=#{STATE_FILE} "
      cmd << args.map { |e| "'#{e}'" }.join(" ")

      SCR.Execute(path(".target.bash"), cmd)
    end

    #  Retrieve the data for perl-Bootloader library from Storage module
    #  and pass it along
    #  @return nothing
    # FIXME: this should be done directly in perl-Bootloader through LibStorage.pm
    def SetDiskInfo
      BootStorage.InitDiskInfo

      Builtins.y2milestone(
        "Information about partitioning: %1",
        BootStorage.partinfo
      )
      Builtins.y2milestone(
        "Information about MD arrays: %1",
        BootStorage.md_info
      )
      Builtins.y2milestone(
        "Mapping real disk to multipath: %1",
        BootStorage.multipath_mapping
      )

      TmpYAMLFile.open(BootStorage.mountpoints) do |mp_data|
        TmpYAMLFile.open(BootStorage.partinfo) do |part_data|
          TmpYAMLFile.open(BootStorage.md_info) do |md_data|
            run_pbl_yaml "DefineMountPoints(#{mp_data.path})",
              "DefinePartitions(#{part_data.path})",
              "DefineMDArrays(#{md_data.path})"
          end
        end
      end
      DefineMultipath(BootStorage.multipath_mapping)

      nil
    end

    # Initialize the bootloader library
    # @param [Boolean] force boolean true if the initialization is to be forced
    # @param [String] loader string the loader to initialize the library for
    # @return [Boolean] true on success
    def InitializeLibrary(force, loader)
      return false if !force && loader == @library_initialized

      SCR.Execute(Path.new(".target.remove"), STATE_FILE) # remove old state file to do clear initialization

      Builtins.y2milestone("Initializing lib for %1", loader)
      architecture = BootArch.StrArch
      TmpYAMLFile.open([loader, architecture]) do |loader_data|
        TmpYAMLFile.open(::Bootloader::UdevMapping.to_hash) do |udev_data|
          run_pbl_yaml "SetLoaderType(@#{loader_data.path})",
            "DefineUdevMapping(#{udev_data.path})"
        end
      end

      Builtins.y2milestone("Putting partitioning into library")
      # pass all needed disk/partition information to library
      SetDiskInfo()
      Builtins.y2milestone("Library initialization finished")
      @library_initialized = loader
      true
    end

    # Set boot loader sections
    # @param [Array<Hash{String => Object>}] sections a list of all loader sections (as maps)
    # @return [Boolean] true on success
    def SetSections(sections)
      sections = deep_copy(sections)
      sections = Builtins.maplist(sections) do |s|
        if Mode.normal
          if Ops.get_boolean(s, "__changed", false) ||
              Ops.get_boolean(s, "__auto", false)
            Ops.set(s, "__modified", "1")
          end
        else
          Ops.set(s, "__modified", "1")
        end
        deep_copy(s)
      end
      Builtins.y2milestone("Storing bootloader sections %1", sections)
      TmpYAMLFile.open(sections) do |sections_data|
        run_pbl_yaml "SetSections(#{sections_data.path})"
      end

      true
    end

    # Get boot loader sections
    # @return a list of all loader sections (as maps)
    def GetSections
      TmpYAMLFile.open do |sections_data|
        Builtins.y2milestone("Reading bootloader sections")
        run_pbl_yaml "#{sections_data.path}=GetSections()"
        sects = sections_data.data
        if sects.nil?
          Builtins.y2error("Reading sections failed")
          return []
        end
        Builtins.y2milestone("Read sections: %1", sects)

        sects
      end
    end

    # Set global bootloader options
    # @param [Hash{String => String}] globals a map of global bootloader options
    # @return [Boolean] true on success
    def SetGlobal(globals)
      globals = deep_copy(globals)
      Builtins.y2milestone("Storing global settings %1", globals)
      Ops.set(globals, "__modified", "1")
      TmpYAMLFile.open(globals) do |globals_data|
        run_pbl_yaml "SetGlobalSettings(#{globals_data.path})"
      end

      true
    end

    # Get global bootloader options
    # @return a map of global bootloader options
    def GetGlobal
      Builtins.y2milestone("Reading bootloader global settings")
      TmpYAMLFile.open do |globals_data|
        run_pbl_yaml "#{globals_data.path}=GetGlobalSettings()"
        glob = globals_data.data

        if glob.nil?
          Builtins.y2error("Reading global settings failed")
          return {}
        end

        Builtins.y2milestone("Read global settings: %1", glob)
        glob
      end
    end

    # Set the device mapping (Linux <-> Firmware)
    # @param [Hash{String => String}] device_map a map from Linux device to Firmware device identification
    # @return [Boolean] true on success
    def SetDeviceMap(device_map)
      Builtins.y2milestone("Storing device map #{device_map}")
      TmpYAMLFile.open(device_map) do |arg_data|
        run_pbl_yaml "SetDeviceMapping(#{arg_data.path})"
      end

      true
    end

    # Set the mapping (real device <-> multipath)
    # @param  map<string,string> map from real device to multipath device
    # @return [Boolean] true on success
    def DefineMultipath(multipath_map)
      Builtins.y2milestone("Storing multipath map: %1", multipath_map)
      if Builtins.size(multipath_map) == 0
        Builtins.y2milestone("Multipath was not detected")
        return true
      end

      TmpYAMLFile.open(multipath_map) do |arg_data|
        run_pbl_yaml "DefineMultipath(#{arg_data.path})"
      end

      true
    end

    # Get the device mapping (Linux <-> Firmware)
    # @return a map from Linux device to Firmware device identification
    def GetDeviceMap
      Builtins.y2milestone("Reading device mapping")

      TmpYAMLFile.open do |res_data|
        run_pbl_yaml "#{res_data.path}=GetDeviceMapping()"

        devmap = res_data.data

        if !devmap
          Builtins.y2error("Reading device mapping failed")
          return {}
        end

        Builtins.y2milestone("Read device mapping: %1", devmap)
        devmap
      end
    end

    # Read the files from the system to internal cache of the library
    # @param [Boolean] avoid_reading_device_map do not read the device map, but use internal
    # data
    # @return [Boolean] true on success
    def ReadFiles(avoid_reading_device_map)
      Builtins.y2milestone("Reading Files")

      TmpYAMLFile.open(avoid_reading_device_map) do |param_data|
        run_pbl_yaml "ReadSettings(#{param_data.path})"
      end

      true
    end

    # Flush the internal cache of the library to the disk
    # @return [Boolean] true on success
    def CommitSettings
      Builtins.y2milestone("Writing files to system")
      run_pbl_yaml "WriteSettings()"

      true
    end

    # Update the bootloader settings, make updated saved settings active
    # @return [Boolean] true on success
    def UpdateBootloader
      # true mean avoid init of bootloader
      TmpYAMLFile.open(true) do |arg_data|
        Builtins.y2milestone("Updating bootloader configuration")
        run_pbl_yaml "UpdateBootloader(#{arg_data.path})"
      end
    end

    def SetSecureBoot(enable)
      Builtins.y2milestone("Set SecureBoot #{enable}")
      TmpYAMLFile.open(enable) do |arg_data|
        run_pbl_yaml "SetSecureBoot(#{arg_data.path})"
      end

      true
    end

    # Update append in from boot section, it means take value from "console"
    # and add it to "append"
    #
    # @param [String] append from section
    # @param [String] console from section
    # @return [String] updated append with console
    def UpdateSerialConsole(append, console)
      Builtins.y2milestone(
        "Updating append: %1 with console: %2",
        append,
        console
      )

      TmpYAMLFile.open([append, console]) do |args_data|
        TmpYAMLFile.open do |append_data|
          run_pbl_yaml "#{append_data.path}=UpdateSerialConsole(@#{args_data.path})"

          append_data.data
        end
      end
    end

    # Initialize the boot loader (eg. modify firmware, depending on architecture)
    # @return [Boolean] true on success
    def InitializeBootloader
      TmpYAMLFile.open do |ret_data|
        run_pbl_yaml "#{ret_data.path}=InitializeBootloader()"
        ret = ret_data.data
        Builtins.y2milestone("Initializing bootloader ret: #{ret.inspect}")

        # perl have slightly different evaluation of boolean, so lets convert it
        ret = ![false, nil, 0, ""].include?(ret)
        ret
      end
    end

    # Get contents of files from the library cache
    # @return a map filename -> contents, empty map in case of fail
    def GetFilesContents
      Builtins.y2milestone("Getting contents of files")
      TmpYAMLFile.open do |ret_data|
        run_pbl_yaml "#{ret_data.path}=GetFilesContents()"

        ret = ret_data.data
        if ret.nil?
          Builtins.y2error("Getting contents of files failed")
          return {}
        end

        ret
      end
    end

    # Set the contents of all files to library cache
    # @param [Hash{String => String}] files a map filename -> contents
    # @return [Boolean] true on success
    def SetFilesContents(files)
      Builtins.y2milestone("Storing contents of files")

      TmpYAMLFile.open(files) do |files_data|
        run_pbl_yaml "SetFilesContents(#{files_data.path})"
      end

      true
    end

    # Analyse content of MBR
    #
    # @param [String] device name ("/dev/sda")
    # @return [String] result of analyse ("GRUB stage1", "uknown",...)
    def examineMBR(device)
      TmpYAMLFile.open(device) do |device_data|
        TmpYAMLFile.open do |ret_data|
          run_pbl_yaml "#{ret_data.path}=ExamineMBR(#{device_data.path})"
          ret = ret_data.data

          Builtins.y2milestone("Device: %1 includes in MBR: %2", device, ret)
          ret
        end
      end
    end
  end
end
