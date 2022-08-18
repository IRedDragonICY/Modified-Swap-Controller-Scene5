#! /vendor/bin/sh
MODDIR=${0%/*}

module_version=`grep '^versionCode=' $MODDIR/module.prop | cut -f2 -d '='`

setprop vtools.swap.module "$module_version"

log_file=/cache/lmkd_opt.log
log()
{
  echo "$1" >> $log_file
}
# 清空日志
echo -n '' > $log_file


log_file2=/cache/cgroup_opt.log
log2()
{
  echo "$1" >> $log_file2
}
# 清空日志
echo -n '' > $log_file2





# 应用配置
sh /system/bin/scene_swap_module.sh >> $log_file 2>&1

log ""
log "全部完成！"









# 应用配置
sh /system/bin/scene_swap_extra.sh >> $log_file2 2>&1

log2 ""
log2 "全部完成！"







# 开机后trim一下，有助于尽量保持写入速度
busybox=/data/adb/magisk/busybox
if [[ -f $busybox ]]; then
  sm fstrim 2>/dev/null
  $busybox fstrim /data 2>/dev/null
  $busybox fstrim /cache 2>/dev/null
  $busybox fstrim /system 2>/dev/null
  # $busybox fstrim /data 2>/dev/null
  # $busybox fstrim /cache 2>/dev/null
  # $busybox fstrim /system 2>/dev/null
  sm fstrim 2>/dev/null
fi
