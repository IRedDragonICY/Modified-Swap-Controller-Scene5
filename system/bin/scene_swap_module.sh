echo "关闭ZRAM"
swapoff /dev/block/zram0 2>/dev/null
swapoff /dev/block/zram1 2>/dev/null
swapoff /dev/block/zram2 2>/dev/null

if [[ -f /system/bin/swapon ]]; then
  alias swapon="/system/bin/swapon"
  alias swapoff="/system/bin/swapoff"
  alias mkswap="/system/bin/mkswap"
elif [[ -f /vendor/bin/swapon ]]; then
  alias swapon="/vendor/bin/swapon"
  alias swapoff="/vendor/bin/swapoff"
  alias mkswap="/vendor/bin/mkswap"
fi

if [[ -f /system/bin/dd ]]; then
  alias dd="/system/bin/dd"
elif [[ -f /vendor/bin/dd ]]; then
  alias dd="/vendor/bin/dd"
fi

# alias losetup="busybox losetup"

swap_config="/data/swap_config.conf"
function get_prop() {
  cat $swap_config | grep -v '^#' | grep "^$1=" | cut -f2 -d '='
}

# set_value value path
set_value() {
  if [[ -f $2 ]]; then
    chmod 644 $2 2>/dev/null
    echo $1 > $2
  fi
}

sdk=`getprop ro.system.build.version.sdk`

# get_prop prop
# 解析配置
swap_enable=$(get_prop swap)
swap_size=$(get_prop swap_size)
swap_priority=$(get_prop swap_priority)
swap_use_loop=$(get_prop swap_use_loop)
zram_enable=$(get_prop zram)
zram_writeback=$(get_prop zram_writeback)
zram_size=$(get_prop zram_size)
swappiness=$(get_prop swappiness)
extra_free_kbytes=$(get_prop extra_free_kbytes)
comp_algorithm=$(get_prop comp_algorithm)
watermark_scale_factor=$(get_prop watermark_scale_factor)
enable_process_reclaim=$(get_prop enable_process_reclaim)
mi_reclaim=$(get_prop mi_reclaim)

swapdir="/data"
swapfile="${swapdir}/swapfile"
recreate="${swapdir}/swap_recreate"

MemTotalStr=`cat /proc/meminfo | grep MemTotal`
MemTotalKB=${MemTotalStr:16:8}

loop_save="vtools.swap.loop"
next_loop_path=""

# 获取下一个可用的loop设备
get_next_loop() {
  local current_loop=`getprop $loop_save`

  if [[ "$current_loop" != "" ]]; then
    next_loop_path="$current_loop"
    return
  fi
  
  losetup -f >/dev/null 2>&1
  local nl=$(losetup -f | egrep -o '[0-9]{1,}' 2>/dev/null)
  if [[ "$nl" != "" ]]; then
    next_loop_path="/dev/block/loop$nl"
    return
  fi

  local loop_index=0
  local used=`blkid | grep /dev/block/loop`
  for loop in /dev/block/loop*
  do
    if [[ "$loop_index" -gt "0" ]]; then
      if [[ `echo $used | grep /dev/block/loop$loop_index` = "" ]]; then
        next_loop_path="/dev/block/loop$loop_index"
        return
      fi
    fi
    local loop_index=`expr $loop_index + 1`
  done

  next_loop_path=""
}

set_swap() {
  echo "*************************"

  # 判断是否需要重新创建文件
  if [[ -f ${recreate} ]]; then
    rm -rf ${swapfile}*
    rm -f ${recreate}
    echo "删除已有swapfile"
  fi

  if [[ "$swap_enable" == "true" ]] && ([[ "$swap_size" != "" ]] || [[ -f ${swapfile} ]]); then
    echo "设置Swapfile"
    set_value true /sys/kernel/mm/swap/vma_ra_enabled

    # mkdir -p ${swapdir}

    # 是否已经创建文件
    if [[ ! -f ${swapfile} ]]; then
      echo "    创建swapfile"
      dd if=/dev/zero of=${swapfile} bs=1m count=${swap_size} > /dev/null
      chmod 666 ${swapfile} > /dev/null
      chown system:system ${swapfile} > /dev/null
    fi

    # 记录挂载点
    swap_mount=$swapfile

    # 如果需要挂载为回环设备，则先挂载并记录挂载点参数
    if [[ $swap_use_loop == "true" ]]; then
      echo "    获取下一个可用回环设备"
      get_next_loop

      if [[ "$next_loop_path" != "" ]]; then
        swap_mount=$next_loop_path
      else
        echo '  所有回环设备都已被占用，SWAP无法完成挂载！' 1>&2
        return
      fi

      # losetup $swap_mount $swapfile # 挂载
      if [[ -e $swap_mount ]]; then
        echo "    删除已有回环设备" 
        losetup -d $swap_mount 2>/dev/null
      fi

      echo "    初始化swapfile"
      mkswap ${swapfile} >/dev/null

      echo "    挂载回环设备 $swap_mount"
      losetup $swap_mount $swapfile

      setprop $loop_save $next_loop_path
    else
      echo "    初始化swapfile"
      mkswap ${swap_mount} >/dev/null
    fi

    echo "    开启Swapfile"
    # 判断是否自定义优先级
    if [[ "$swap_priority" != "" ]] && [[ "$swap_priority" -gt -1 ]]; then
      swapon ${swap_mount} -p $swap_priority >/dev/null
    else
      swapon ${swap_mount} >/dev/null
    fi
  else
    echo "未启用Swapfile"
  fi
}

set_zram() {
  echo "*************************"
  if [[ ! -e /dev/block/zram0 ]]; then
    if [[ -e /sys/class/zram-control ]]; then
      cat /sys/class/zram-control/hot_add
    else
      echo '  内核不支持ZRAM!'
      return
    fi
  fi

  if [[ "$zram_enable" == "true" ]] && [[ "$zram_size" != "" ]]; then
    echo "设置ZRAM"

    repeat=0
    while [[ $repeat -lt 25 ]]; do
      swapoff /dev/block/zram0 2>/dev/null
      swapoff /dev/block/zram1 2>/dev/null
      repeat=$(($repeat+1))
      sleep 1
    done

    current_disksize=`cat /sys/block/zram0/disksize`
    target_disksize="${zram_size}m"

    # 读取 ZRAM Writeback配置
    local backing_dev=''
    local bd_path=/sys/block/zram0/backing_dev
    if [[ -f $bd_path ]]; then
      local backing_dev=$(cat $bd_path)
    fi

    echo "    重置ZRAM"
    swapoff /dev/block/zram0 2>/dev/null
    swapoff /dev/block/zram1 2>/dev/null
    if [[ "$zram_size" == "0" ]]; then
      return
    fi
    set_value 1 /sys/block/zram0/reset
    set_value 4 /sys/block/zram0/max_comp_streams

    if [[ -f $bd_path ]]; then
      # 配置ZRAM Writeback
      if [[ "$zram_writeback" == "true" ]]; then
        set_zram_writeback
      elif [[ "$zram_writeback" == "default" ]]; then
        # 正常情况，关闭重启zram并不会导致backing_dev设置失效，但保险起见还是恢复配置一次
        if [[ "$backing_dev" != '' ]] && [[ "$backing_dev" != 'none' ]]; then
          set_value "$backing_dev" $bd_path
        fi
      else
        # 禁用 ZRAM Writeback
        set_value none $bd_path
        set_value 1 /sys/block/zram0/writeback_limit_enable
        set_value 0 /sys/block/zram0/writeback_limit
      fi
    fi

    echo "    设置ZRAM压缩方式"
    if [[ "$comp_algorithm" != "" ]]; then
      check_result=`cat /sys/block/zram0/comp_algorithm | grep $comp_algorithm`
      if [[ "$check_result" != "" ]]; then
        echo $comp_algorithm > /sys/block/zram0/comp_algorithm
      else
        echo "      压缩方式[$comp_algorithm] 内核不支持！"
      fi
    fi

    set_value 4 /sys/block/zram0/max_comp_streams

    echo "    设置ZRAM大小"
    echo $target_disksize > /sys/block/zram0/disksize

    echo "    初始化ZRAM"
    mkswap /dev/block/zram0

    echo "    启动ZRAM"
    if [[ "$swap_priority" == "0" ]]; then
      swapon /dev/block/zram0 -p 0 >/dev/null
    else
      swapon /dev/block/zram0 >/dev/null
    fi
  else
    sleep 25
    echo "未配置ZRAM"
  fi

  # setprop persist.sys.zram_enabled 1
}

set_vm_params() {
  echo "*************************"
  if [[ "$watermark_scale_factor" != "" ]]; then
    echo "设置watermark_scale_factor $watermark_scale_factor"
    set_value "$watermark_scale_factor" /proc/sys/vm/watermark_scale_factor
  else
    echo "未配置watermark_scale_factor"
  fi
  set_value 0 /proc/sys/vm/watermark_boost_factor

  local path='/proc/sys/vm/extra_free_kbytes'
  if [[ "$extra_free_kbytes" != "" ]]; then
    echo "设置min_free_kbytes [$extra_free_kbytes]"
    set_value "$extra_free_kbytes" $path
    resetprop sys.sysctl.extra_free_kbytes "$extra_free_kbytes"
  else
    echo "未配置min_free_kbytes"
  fi

  if [[ "$swappiness" != "" ]]; then
    echo "设置swappiness [$swappiness]"
    echo $swappiness > /proc/sys/vm/swappiness
    set_value $swappiness /dev/memcg/memory.swappiness
    set_value $swappiness /dev/memcg/apps/memory.swappiness
    set_value $swappiness /sys/fs/cgroup/memory/apps/memory.swappiness
    set_value $swappiness /sys/fs/cgroup/memory/memory.swappiness
  else
    echo "未配置swappiness"
  fi

  echo "设置cache"
  # 降低了读写缓存，对于目前的UFS3闪存来说，IO性能足够，并不需要太多内存缓存来提高性能
  set_value 2 /proc/sys/vm/dirty_background_ratio
  set_value 5 /proc/sys/vm/dirty_ratio
  set_value 3000 /proc/sys/vm/dirty_expire_centisecs
  set_value 5000 /proc/sys/vm/dirty_writeback_centisecs
  set_value 150 /proc/sys/vm/vfs_cache_pressure
  # set_value 128 /sys/block/sda/queue/read_ahead_kb

  echo "设置其它vm参数"
  # set_value 1 /proc/sys/vm/swap_ratio_enable
  # set_value 75 /proc/sys/vm/swap_ratio
  set_value 0 /proc/sys/vm/swap_ratio_enable

  # 
  set_value 0 /sys/module/vmpressure/parameters/allocstall_threshold
  # 每次换入的内存页，3表示2的三次方，即8页
  #   每页的大小可以通过 `getcon PAGESIZE` 查看，一般是4KB
  set_value 3 /proc/sys/vm/page-cluster
  # 杀死触发oom的那个进程
  set_value 0 /proc/sys/vm/oom_kill_allocating_task
  # 是否打印 oom日志
  set_value 0 /proc/sys/vm/oom_dump_tasks
  # 是否要允许压缩匿名页
  set_value 1 /proc/sys/vm/compact_unevictable_allowed
  # vm 状态更新频率
  set_value 1 /proc/sys/vm/stat_interval
  # CommitLimit=Swap+Zram+(RAM * overcommit_ratio / 100)
  set_value 30 /proc/sys/vm/overcommit_ratio
  set_value 1 /proc/sys/vm/overcommit_memory
  # 触发oom后怎么抛异常
  set_value 1 /proc/sys/vm/panic_on_oom
}

set_lmk_params() {
  echo "*************************"
  echo "设置lmk参数"
  sleep 15

  # for MIUI 12
  resetprop persist.sys.minfree_6g "16384,20480,32768,131072,230400,286720"
  resetprop persist.sys.minfree_8g "16384,20480,32768,131072,384000,524288"
  if [[ $MemTotalKB -gt 6291456 ]]; then
    resetprop persist.sys.minfree_def "16384,20480,32768,131072,384000,524288"
  else
    resetprop persist.sys.minfree_def "16384,20480,32768,131072,230400,286720"
  fi


  lowmemorykiller='/sys/module/lowmemorykiller/parameters'
  # Linux Kernel 4.9 前的内核
  if [[ -d $lowmemorykiller ]]; then
    # > 8G
    if [[ $MemTotalKB -gt 8388608 ]]; then
      set_value "4096,5120,32768,96000,131072,204800" $lowmemorykiller/minfree
    # > 6G
    elif [[ $MemTotalKB -gt 6291456 ]]; then
      set_value "4096,5120,8192,32768,96000,131072" $lowmemorykiller/minfree
    # > 4GB
    elif [[ $MemTotalKB -gt 4194304 ]]; then
      set_value "4096,5120,8192,32768,56320,71680" $lowmemorykiller/minfree
    # > 3GB
    elif [[ $MemTotalKB -gt 3145728 ]]; then
      set_value "4096,5120,8192,24576,32768,47360" $lowmemorykiller/minfree
    # > 2GB
    elif [[ $MemTotalKB -gt 2097152 ]]; then
      set_value "4096,5120,8192,16384,24576,39936" $lowmemorykiller/minfree
    else
      set_value "4096,5120,8192,10240,16384,24576" $lowmemorykiller/minfree
    fi

    set_value 53059 $lowmemorykiller/vmpressure_file_min
    set_value 0 $lowmemorykiller/enable_adaptive_lmk
    set_value 1 $lowmemorykiller/oom_reaper

  # Android Q+
  elif [[ $sdk -gt 28 ]]; then
    minfree_levels=""
    # > 8G
    if [[ $MemTotalKB -gt 8388608 ]]; then
      minfree_levels="4096:0,5120:100,32768:200,96000:250,131072:900,204800:950"
    # > 6G
    elif [[ $MemTotalKB -gt 6291456 ]]; then
      minfree_levels="4096:0,5120:100,8192:200,32768:250,96000:900,131072:950"
    # > 4GB
    elif [[ $MemTotalKB -gt 4194304 ]]; then
      minfree_levels="4096:0,5120:100,8192:200,32768:250,56320:900,71680:950"
    # > 3GB
    elif [[ $MemTotalKB -gt 3145728 ]]; then
      minfree_levels="4096:0,5120:100,8192:200,24576:250,32768:900,47360:950"
    # > 2GB
    elif [[ $MemTotalKB -gt 2097152 ]]; then
      minfree_levels="4096:0,5120:100,8192:200,16384:250,24576:900,39936:950"
    else
      minfree_levels="4096:0,5120:100,8192:200,10240:250,16384:900,24576:950"
    fi

    resetprop sys.lmk.minfree_levels $minfree_levels
    stop lmkd
    start lmkd
    resetprop sys.lmk.minfree_levels $minfree_levels

    # 版本低于4.12的内核还会保留lowmemorykiller
    # 但禁用它可能导致内存不足时死机
    # set_value 0 /sys/module/lowmemorykiller/parameters/enable_lmk
  fi
}

set_ppr() {
  echo "*************************"
  # set_value 0 /sys/kernel/debug/rtmm/reclaim/auto_reclaim_max
  # set_value 0 /sys/kernel/debug/rtmm/reclaim/default_reclaim_swappiness
  # set_value 0 /sys/kernel/debug/rtmm/reclaim/global_reclaim_max
  ppr=/sys/module/process_reclaim/parameters
  # process_reclaim 高通特有，优缺点同样明显(能有效提高swap效率，但会增加额外的开销)
  # 开启了Swapfile > 512MB，且设为ZRAM用完后使用，才允许开启process_reclaim，否则忽略配置
  if [[ -d $ppr ]]; then
    echo "配置PPR [$enable_process_reclaim]"

    if [[ "$enable_process_reclaim" == "true" ]]; then
      if [[ "$swap_enable" == "true" ]] &&
         [[ "$swap_priority" == "-2" ]] &&
         [[ "$zram_enable" == "true" ]] &&
         [[ "$zram_size" -gt 512 ]] &&
         [[ "$swap_size" -gt 512 ]];
      then
        set_value 90 $ppr/pressure_max
        set_value 70 $ppr/pressure_min
        # > 8G
        if [[ $MemTotalKB -gt 8388608 ]]; then
          set_value 768 $ppr/per_swap_size # 默认512
        # > 6G
        elif [[ $MemTotalKB -gt 6291456 ]]; then
          set_value 512 $ppr/per_swap_size # 默认512
        # > 4GB
        elif [[ $MemTotalKB -gt 4194304 ]]; then
          set_value 384 $ppr/per_swap_size # 默认512
        # > 3GB
        elif [[ $MemTotalKB -gt 3145728 ]]; then
          set_value 256 $ppr/per_swap_size # 默认512
        else
          set_value 128 $ppr/per_swap_size # 默认512
        fi
        set_value 1 $ppr/enable_process_reclaim
        echo '  已启用'
      else
        echo '  未启用(原因 当前SWAP配置不推荐使用PPR)'
      fi
    else
      set_value 0 $ppr/enable_process_reclaim
    fi
  else
    echo "不支持PPR"
  fi
}

set_zram_writeback() {
  if [[ ! -f /data/writeback ]]; then
    local size=$zram_size
    if [[ "$size" == '' ]]; then
      local size=2048
    fi
    dd if=/dev/zero of=/data/writeback bs=1m count=$size
    chmod 664 /data/writeback 2>/dev/null
    chown system:system /data/writeback 2>/dev/null
  fi

  losetup -f 2>/dev/null
  local nl=$(losetup -f | egrep -o '[0-9]{1,}' 2>/dev/null)
  if [[ "$nl" == "" ]]; then
    return
  fi

  local loop_path="/dev/block/loop$nl"
  losetup $loop_path /data/writeback
  mkswap $path
  set_value $loop_path /sys/block/zram0/backing_dev
  set_value 0 /sys/block/zram0/writeback_limit_enable
}


dis_mi_reclaim() {
  if [[ "$mi_reclaim" == 'false' ]]; then
    # 禁用 mi_reclaim
    set_value 0 /sys/kernel/mi_reclaim/enable

    # 尝试禁用小米的rtmm
    mi_rtmm=''
    if [[ -d '/d/rtmm' ]]; then
      mi_rtmm=/d/rtmm/reclaim
    elif [[ -d '/sys/kernel/mm/rtmm' ]]; then
      mi_rtmm='/sys/kernel/mm/rtmm'
    else
      return
    fi

    chmod 000 $mi_rtmm/reclaim/auto_reclaim 2>/dev/null
    chown root:root $mi_rtmm/reclaim/auto_reclaim 2>/dev/null
    chmod 000 $mi_rtmm/reclaim/global_reclaim 2>/dev/null
    chown root:root $mi_rtmm/reclaim/global_reclaim 2>/dev/null
    chmod 000 $mi_rtmm/reclaim/proc_reclaim 2>/dev/null
    chown root:root $mi_rtmm/reclaim/proc_reclaim 2>/dev/null
    chmod 000 $mi_rtmm/reclaim/kill 2>/dev/null
    chown root:root $mi_rtmm/reclaim/kill 2>/dev/null
    chown root:root $mi_rtmm/compact/compact_memory 2>/dev/null
  fi
}

set_zram
set_swap
set_ppr
set_vm_params
set_lmk_params
dis_mi_reclaim

set_value 0 /sys/kernel/debug/tracing/tracing_on
