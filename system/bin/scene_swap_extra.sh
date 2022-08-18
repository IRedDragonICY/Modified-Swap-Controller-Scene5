swap_config="/data/swap_config.conf"
get_prop() {
  cat $swap_config | grep -v '^#' | grep "^$1=" | cut -f2 -d '='
}
move_to_cpuset() {
  echo -n "  + $1 $2 "
  # pgrep 精确度有点差
  pgrep -f $2 | while read pid; do
    echo -n "$pid "
    echo $pid > /dev/cpuset/$1/cgroup.procs
  done
  echo ""
}

set_top_app(){
  echo -n "  + top-app $1 "
  # pgrep 精确度有点差
  pgrep -f $1 | while read pid; do
    echo -n "$pid "
    echo $pid > /dev/cpuset/top-app/cgroup.procs
    echo $pid > /dev/stune/top-app/cgroup.procs
  done
  echo ""
}

# get_prop prop
# 解析配置
enhanced_service=$(get_prop enhanced_service)
MemTotalStr=`cat /proc/meminfo | grep MemTotal`
SwapTotal=`cat /proc/meminfo | grep SwapTotal`
MemTotalKB=${MemTotalStr:16:8}
SwapTotalKB=${SwapTotal:16:8}

zramSizeStr=''
zramSizeKB=''
if [[ -f /sys/block/zram0/disksize ]]; then
  zramSizeStr=$(cat /sys/block/zram0/disksize)
  zramSizeKB=$((zramSizeStr / 1024))
fi

if [[ "$enhanced_service" == "" ]]; then
  # 未配置或不支持
  exit 0
elif [[ "$enhanced_service" == "off" ]]; then
  echo '未启用[enhanced_service]'
  exit 0
fi

echo "设置cpuset"
set_top_app vendor.qti.hardware.display.composer-service
set_top_app android.hardware.graphics.composer
set_top_app surfaceflinger
set_top_app system_server
set_top_app servicemanager
set_top_app com.android.permissioncontroller

if [[ "$enhanced_service" != "basic" ]]; then
  if [[ ! $MemTotalKB -gt 4194304 ]]; then
    echo '  设备内存低于6GB'
    echo '  已将配置调整为[basic]'
    enhanced_service="basic"
  elif [[ ! $SwapTotalKB -gt 1572864 ]]; then
    echo '  SWAP低于1.5GB'
    echo '  已将配置调整为[basic]'
    enhanced_service="basic"
  else
    backing_dev=''
    if [[ -f /sys/block/zram0/backing_dev ]]; then
      backing_dev=$(cat /sys/block/zram0/backing_dev)
    fi

    # 如果不支持ZRAM Writeback 或者未正确配置 backing_dev
    if [[ "$backing_dev" == '' ]] || [[ "$backing_dev" == 'none' ]];then
      # ZRAM设置过大
      if [[ "$zramSizeKB" != "" ]] && [[ "$zramSizeKB" -gt $((MemTotalKB / 3)) ]]; then
        echo '  ZRAM > RAM的1/3'
        echo '  已将配置调整为[basic]'
        enhanced_service="basic"
      fi
    fi
  fi
fi

echo "创建cgroup"
if [[ -d /sys/fs/cgroup/memory ]]; then
  scene_memcg="/sys/fs/cgroup/memory"
elif [[ -d /dev/memcg ]]; then
  scene_memcg="/dev/memcg"
fi

init_group() {
  local g=$scene_memcg/$1
  if [[ ! -d $g ]]; then
    mkdir -p $g
  fi
  echo $2 > $g/memory.swappiness
  echo 1 > $g/memory.oom_control
  echo 1 > $g/memory.use_hierarchy
}

if [[ "$scene_memcg" != "" ]] && [[ -e /proc/1/reclaim ]]; then
  limit=''
  g_swappiness=''
  a_swappiness='0'
  if [[ "$enhanced_service" == "basic" ]]; then
    g_swappiness=$(cat $scene_memcg/memory.swappiness)
    a_swappiness=$g_swappiness
    limit='-1'
  elif [[ "$enhanced_service" == "lazy" ]]; then
    g_swappiness='20'
    limit='-1'
  elif [[ "$enhanced_service" == "active" ]]; then
    g_swappiness='20'
    limit=$((MemTotalKB/1024/10))M
  elif [[ "$enhanced_service" == "force" ]]; then
    g_swappiness='0'
    limit=$((MemTotalKB/1024/30))M
  else
    g_swappiness='20'
    limit=$((MemTotalKB/1024/4))M
  fi

  # init_group scene_fg 0
  init_group scene_active $a_swappiness
  # init_group scene_bg 100
  init_group scene_idle 100

  if [[ -f $scene_memcg/sys_critical/memory.swappiness ]]; then
    echo 0 > $scene_memcg/sys_critical/memory.swappiness
  fi
  if [[ -f $scene_memcg/system/memory.swappiness ]]; then
    echo 0 > $scene_memcg/system/memory.swappiness
  fi

  if [[ "$enhanced_service" != "basic" ]]; then
    find $scene_memcg -name memory.move_charge_at_immigrate | while read row; do
      echo 1 > $row
    done
  fi

  echo $g_swappiness > $scene_memcg/memory.swappiness
  echo $limit > $scene_memcg/scene_idle/memory.soft_limit_in_bytes
else
  if [[ "$enhanced_service" != "basic" ]]; then
    enhanced_service="basic"
  fi
  echo "  你的内核不支持cgroup(memory)"
fi


echo "启动cgroup配置服务"
nohup dalvikvm -cp /system/bin/scene_swap_service.dex Main $enhanced_service > /dev/null 2>&1 &
