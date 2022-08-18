SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=true
LATESTARTSERVICE=true

REPLACE="
"

print_modname() {
  ui_print "*******************************"
  ui_print "     Module author: 嘟嘟ski    "
  ui_print "*******************************"
  ui_print " "
  ui_print " 配置参数位于 /data/swap_config.conf 可自行修改 "
  ui_print " 或配合Scene3.4.6及以后的版本 "
  ui_print " 可直接在 SWAP设置 里调节模块配置"
  ui_print " "
  ui_print " "
}


set_permissions() {
  set_perm_recursive $MODPATH/system 0 0 0755 0644
}


origin_dir="/system/vendor/etc/perf"
origin_file="$origin_dir/perfconfigstore.xml"
overlay_dir="$MODPATH$origin_dir"
overlay_file="$MODPATH$origin_file"


old_module_file=/data/adb/modules/scene_swap_controller$origin_dir/perfconfigstore.xml
if [[ -e $old_module_file ]]; then
  old_module_version=`grep '^versionCode=' /data/adb/modules/scene_swap_controller/module.prop | cut -f2 -d '='`
  if [[ "$old_module_version" == "" ]] || [[ "$old_module_version" -lt 2000 ]]; then
    ui_print ''
    ui_print ''
    ui_print '请删除旧版模块并重启手机，回来再安装！'
    ui_print ''
    ui_print ''
    exit 2
  fi
fi


swap_config="/data/swap_config.conf"



# update_overlay ro.lmk.enhance_batch_kill false
update_overlay() {
  local prop="$1"
  local value="$2"
  sed -i "s/Name=\"$prop\" Value=\".*\"/Name=\"$prop\" Value=\"$value\"/" $overlay_file
}
update_system_prop() {
  local prop="$1"
  local value="$2"
  sed -i "s/^$prop=.*/$prop=$value/" $TMPDIR/system.prop
}

get_prop() {
  cat $swap_config | grep "^$1=" | cut -f2 -d '='
}

# 解析旧版模块创建的配置（读取以便保留部分用户自定义配置）
read_current_config() {
  if [[ -f $swap_config ]]; then
    current_swap_enable=$(get_prop swap)
    current_swap_size=$(get_prop swap_size)
    current_swap_use_loop=$(get_prop swap_use_loop)
    current_zram_enable=$(get_prop zram)
    current_zram_size=$(get_prop zram_size)
    current_enhanced_service=$(get_prop enhanced_service)
    current_mi_reclaim=$(get_prop mi_reclaim)

    if [[ "$current_zram_enable" != "" ]] && [[ "$current_zram_size" != "" ]]; then
      zram_enable="$current_zram_enable"
      zram_size="$current_zram_size"
    fi
    if [[ "$current_swap_enable" != "" ]] && [[ "$current_swap_size" != "" ]]; then
      swap_enable="$current_swap_enable"
      swap_size="$current_swap_size"
    fi
    if [[ "$current_swap_use_loop" != "" ]]; then
      swap_use_loop="$current_swap_use_loop"
    fi
    if [[ "$current_enhanced_service" != "" ]]; then
      enhanced_service="$current_enhanced_service"
    fi
    if [[ "$current_mi_reclaim" != "" ]]; then
      mi_reclaim="$current_mi_reclaim"
    fi
  fi
}

# 检测UFS健康
ufs_health_check() {
  # 0x00	未找到有关设备使用寿命的信息。
  # 0x01	设备估计使用寿命的 0% 到 10%。
  # 0x02	设备估计使用寿命的 10% 到 20%。
  # 0x03	设备估计使用寿命的 20% 到 30%。
  # 0x04	设备估计使用寿命的 30% 到 40%。
  # 0x05	设备估计使用寿命的 40% 到 50%。
  # 0x06	设备估计使用寿命的 50% 到 60%。
  # 0x07	设备估计使用寿命的 60% 到 70%。
  # 0x08	设备估计使用寿命的 70% 到 80%。
  # 0x09	设备估计使用寿命的 80% 到 90%。
  # 0x0A	设备估计使用寿命的 90% 到 100%。
  # 0x0B	设备已超过其估计的使用寿命。
  bDeviceLifeTimeEstA=$(cat /sys/kernel/debug/*.ufshc/dump_health_desc | grep bDeviceLifeTimeEstA | cut -f2 -d '=' | cut -f2 -d ' ')

  # 0x00	未定义成员。
  # 0x01	正常。消耗不到 80% 的保留区块。
  # 0x02	消耗了 80% 的保留区块。
  # 0x03	危急。消耗了 90% 的保留区块。
  # 所有其他值	保留供将来使用。

  bPreEOLInfo=$(cat /sys/kernel/debug/*.ufshc/dump_health_desc | grep bPreEOLInfo | cut -f2 -d '=' | cut -f2 -d ' ')
  if [[ "$bDeviceLifeTimeEstA" == "0x01" ]] || [[ "$bDeviceLifeTimeEstA" == "0x1" ]]; then
    if [[ "$bPreEOLInfo" == "0x01" ]] || [[ "$bPreEOLInfo" == "0x1" ]]; then
      return 1
    fi
  elif [[ "$bDeviceLifeTimeEstA" == "" ]] && [[ "$bPreEOLInfo" == "" ]]; then
    return 1
  fi

  return 0
}

# 根据设备性能自动调整参数
auto_config () {
  MemTotalStr=`cat /proc/meminfo | grep MemTotal`
  MemTotalKB=${MemTotalStr:16:8}
  ui_print "- RAM Total:${MemTotalKB}KB"

  ufs_health_check
  ufs_health_ok=$?
  soc_platform=$(getprop ro.board.platform)

  # > 8GB
  if [[ $MemTotalKB -gt 8388608 ]]; then
    # 865、888性能比较好，可以开点ZRAM提高多任务能力
    if [[ "$soc_platform" == "kona" ]] || [[ "$soc_platform" == "lahaina" ]]; then
      zram_size=3072
    else
      zram_enable="false"
    fi
  # > 6GB
  elif [[ $MemTotalKB -gt 6291456 ]]; then
    zram_size=3072
    # 8G 内存的骁龙865、888...
    if [[ "$soc_platform" == "kona" && "$ufs_health_ok" == "1" ]] || [[ "$soc_platform" == "lahaina" ]]; then
      swap_enable="true"
      swap_size=16024
      zram_size=7552
    fi
  # > 4GB
  elif [[ $MemTotalKB -gt 4194304 ]]; then
    zram_size=2047

    # 6G 内存的骁龙865、888...
    if [[ "$soc_platform" == "kona" -a "$ufs_health_ok" == "1" ]] || [[ "$soc_platform" == "lahaina" ]]; then
      swap_enable="true"
      swap_size=2048
    fi

  # < 4GB
  else
    zram_size=1536
  fi

  if [[ "$zram_enable" == "true" ]]; then
    ui_print "- ZRAM ON ${zram_size}MB"
  else
    ui_print "- ZRAM OFF"
  fi


  sdk_version=$(getprop ro.build.version.sdk)
  top_app="/dev/cpuset/top-app/cgroup.procs"
  bg_app="/dev/cpuset/background/cgroup.procs"
  fg_app="/dev/cpuset/foreground/cgroup.procs"
  if [[ -f $top_app ]] && [[ -f $bg_app ]] && [[ -f $fg_app ]] && [[ "$sdk_version" -gt 27 ]]; then
    if [[ -e /proc/1/reclaim ]] && [[ -d /sys/fs/cgroup/memory || -d /dev/memcg ]]; then
      enhanced_supported=full
      if [[ $MemTotalKB -gt 6291456 ]]; then
        enhanced_service='basic'
      elif [[ $MemTotalKB -gt 4194304 ]]; then
        enhanced_service='basic'
      else
        enhanced_service='basic'
      fi
    else
      enhanced_service='basic'
      enhanced_supported=partial
    fi
  else
    enhanced_supported=none
  fi
}

# 判断是否是特别喜欢杀后台的机型(mi 865)
mi_kona_device () {
  device=$(getprop ro.product.vendor.name)
  manufacturer=$(getprop ro.product.vendor.manufacturer)
  platform=$(getprop ro.board.platform)

  peculiar_device="false"
  # Note: 2.4.0
  # mi 10 pro, mi 10, k30pro 这几个865机型比较特殊，
  # 后台应用oom_score_adj很容易变高超过900，导致很快被杀死
  # 因此针对机型适当的调整配置
  # if [[ "$device" == "cmi" ]] || [[ "$device" == "umi" ]] || [[ "$device" == "umi" ]]; then
  #   return 1
  # else
  #   return 0
  # fi

  # Note: 2.5.0
  # 小米865全系列机型，都特殊对待
  if [[ "$manufacturer" == "Xiaomi" ]] || [[ "$platform" == "kona" ]]; then
    return 1
  else
    return 0
  fi
}

swap_enable=false
swap_size=2047
swap_use_loop=false
zram_enable=true
zram_size=2047
enhanced_service=basic
mi_reclaim=false

enhanced_supported=none


ui_print ''
ui_print ''
ui_print "*******************************"


# 检测是否是小米的 Kona(865)机型
mi_kona_device
kona_device=$?
# 自动配置
auto_config
# 读取已经存在的配置
read_current_config

ui_print "*******************************"
ui_print ''
ui_print ''

on_install() {
  ui_print "- 提取模块文件"
  unzip -o "$ZIPFILE" 'system/*' -d $MODPATH >&2

  echo "" > /data/swap_recreate

# 是否支持ppr
if [[ -d /sys/module/process_reclaim/parameters ]]; then
ppr_config="# 是否启用process_reclaim(Qualcomm特有)
# 按进程回收内存，可有效的提高交换效率(或说积极性)
# 缺点是会增加额外的性能开销，如果开启swapfile还会加剧磁盘磨损
# true : 开启，根据ZRAM、Swapfile配置微调
# false：关闭
enable_process_reclaim=false

"
else
ppr_config=''
fi

# 是否支持 mi_reclaim
if [[ "$manufacturer" == "Xiaomi" ]]; then
mi_reclaim_config="# mi_reclaim/rtmm(仅限MIUI)
# true  保持系统默认
# false 强制禁用mi_reclaim/rtmm
mi_reclaim=$mi_reclaim"
else
mi_reclaim_config=""
fi

# 是否支 enhanced_service
if [[ "$enhanced_supported" == "full" ]]; then

# enhanced_service
# 由模块提供的增强服务，改进Swap使用效率，具体表现为：
# 阻止SWAP前台应用/重要进程占用的内存，并为后台应用设置内存限额
# 使SWAP尽量发生在后台进程上，或能缓解使用SWAP导致的系统性能下滑
# off     禁用 禁用此功能特性
# basic   启用 不限制后台进程内存用量且不更改swap积极性，仅在内存严重不足时强制回收
# lazy    启用 不限制后台进程内存用量，仅在内存严重不足时强制回收
# passive 启用 限制后台进程内存用量，并在内存不足时强制回收
# active  启用 限制后台进程内存用量，并在将要内存不足时强制回收
# force   启用 总是尽可能强制回收后台进程占用的内存(不推荐使用)
# 要求 RAM≥6GB, SWAP≥1.5GB，ZRAM<RAM的1/3

enhanced_service_config="# 由模块提供的增强服务，改进Swap使用效率
# off     禁用 禁用此功能特性
# basic   启用 不限制后台进程内存用量且不更改swap积极性，仅在内存严重不足时强制回收
# lazy    启用 不限制后台进程内存用量，仅在内存严重不足时强制回收
# passive 启用 限制后台进程内存用量，并在内存不足时强制回收
# active  启用 限制后台进程内存用量，并在将要内存不足时强制回收
# 除off和basic外，均要求 RAM≥6GB, SWAP≥1.5GB，ZRAM<RAM的1/3(或已配置ZRAM Writeback)
enhanced_service=$enhanced_service

"

elif [[ "$enhanced_supported" == "partial" ]]; then

enhanced_service_config="# 由模块提供的增强服务，改进Swap使用效率
# off     禁用 禁用此功能特性
# basic   启用 不限制后台进程内存用量且不更改swap积极性，仅在内存严重不足时强制回收
# 您的内核和系统较旧，不支持enhanced_service的更多功能
enhanced_service=$enhanced_service

"
else
enhanced_service_config=''
fi

if [[ -f '/sys/block/zram0/backing_dev' ]]; then
zram_writeback_config="
# ZRAM Writeback（性能较低建议关闭）
# default 保持系统默认配置
# true 开启ZRAM Writeback，并由模块配置回写设备
# false 关闭ZRAM Writeback
zram_writeback=false

"
else
zram_writeback_config=''
fi


  echo "
# 是否配置swapfile
swap=$swap_enable

# swapfile大小(MB)，部分设备超过2047会开启失败
# 注意，修改swap大小，需要手动删除/data/swapfile，才会重新创建
swap_size=$swap_size

# swapfile使用顺序
#  0 与zram同时使用
# -2 用完zram后再使用
#  5 优先于zram使用）
swap_priority=-2

# 是否将swapfile挂载为回环设备
# 在很多设备上性能表现很差。如非必要，不建议开启
swap_use_loop=$swap_use_loop

# 是否配置zram
# 注意: 设为false并不代表禁用zram，而是保持系统默认配置
# 如果你想关闭系统默认开启的zram，则因设为true，并配置zram_size为0
zram=$zram_enable

# zram大小(MB)，部分设备超过2047会开启失败
zram_size=$zram_size

# zram压缩算法(可设置的值取决于内核支持)
# lzo和lz4都很常见，性能也很好
comp_algorithm=lz4

# 使用SWAP的积极性
# 不要设置的太低，避免在内存严重不足时才开始大量回收内存，导致IO压力集中。建议值30~100
swappiness=100

# 额外空余内存(kbytes)
# 数值越大越容易触发swap和内存回收
extra_free_kbytes=25600

# 水位线调整(1到1000，越大内存回收越积极)
# 例如设为1000，则表示10%，表示内存水位线low-min-high之间，各相差RamSize * 10%
# 剩余内存低于low的值开始回收内存，直到内存不低于high的值。如果我有8G物理内存，那么回收10%就是一口气回收了大概800M，这个过程需要消耗不少性能，导致短时间卡住
# 但是设置太小也会导致swap因为每次回收的内存量太少而效率过低，出现连续的卡顿掉帧
# 因此，请酌情设置watermark_scale_factor
watermark_scale_factor=25

$ppr_config
$enhanced_service_config
$zram_writeback_config
$mi_reclaim_config

" > $swap_config
  device=$(getprop ro.product.vendor.name)
  manufacturer=$(getprop ro.product.vendor.manufacturer)
  platform=$(getprop ro.board.platform)

  # 喜欢杀后台的特殊机型，特殊对待
  if [[ "$kona_device" == "1" ]]; then
    update_system_prop ro.lmk.medium 1001
    # 方式1 使用传统LMK
    update_system_prop ro.lmk.use_minfree_levels true
    update_system_prop ro.lmk.use_psi false

    # 方式2 降低PSI报告积极性
    # update_system_prop ro.lmk.psi_partial_stall_ms 350
  fi

  if [[ -f $origin_file ]]
  then
    mkdir -p $overlay_dir
    cp $origin_file $overlay_file

    update_overlay ro.lmk.kill_heaviest_task_dup false
    update_overlay ro.lmk.enhance_batch_kill false
    update_overlay ro.lmk.enable_watermark_check false
    update_overlay ro.lmk.enable_preferred_apps false

    # 喜欢杀后台的特殊机型，特殊对待
    if [[ "$kona_device" == "1" ]]; then
      update_overlay ro.lmk.super_critical 900
    else
      update_overlay ro.lmk.super_critical 800
    fi
    update_overlay ro.lmk.direct_reclaim_pressure 55
    update_overlay ro.lmk.reclaim_scan_threshold 1024

    update_overlay ro.vendor.qti.sys.fw.bg_apps_limit 120

    update_overlay vendor.debug.enable.memperfd false
    update_overlay ro.vendor.perf.enable.prekill false
    update_overlay vendor.appcompact.enable_app_compact false
    update_overlay ro.vendor.qti.am.reschedule_service false
    update_overlay ro.lmk.nstrat_low_swap 10
    ro.lmk.nstrat_psi_partial_ms 150
    ro.lmk.nstrat_psi_complete_ms 700
    ro.lmk.nstrat_psi_scrit_complete_stall_ms 700
  fi
}
