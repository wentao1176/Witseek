#!/usr/bin/env bash
# 生成一个用于演示与截图验证的小工作区。
#
# 存在的意义：在没有 API Key 时也能把界面完整驱动起来（文件树、预览、diff、
# 审批卡片都需要真实文件），同时避免让 agent 去改真正的工程源码。
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
WS="$ROOT/.runtime/demo-workspace"

rm -rf "$WS"
mkdir -p "$WS/app/src/main/java/com/xwt/schedule"
mkdir -p "$WS/app/src/main/res/layout"
mkdir -p "$WS/gradle/wrapper"

cat > "$WS/README.md" <<'MD'
# 大学课表（演示工作区）

这是一个用于演示 Witseek 的小工程，不是真实项目。

## 模块

- `app/` 应用模块
- `gradle/` 构建脚本
MD

cat > "$WS/build.gradle" <<'GRADLE'
plugins {
    id 'com.android.application'
}

android {
    compileSdk 35
    defaultConfig {
        applicationId "com.xwt.schedule"
        minSdk 26
        targetSdk 35
    }
}
GRADLE

cat > "$WS/settings.gradle" <<'GRADLE'
rootProject.name = "class_table"
include ':app'
GRADLE

cat > "$WS/app/src/main/java/com/xwt/schedule/MainActivity.java" <<'JAVA'
package com.xwt.schedule;

import android.os.Bundle;
import android.widget.TextView;
import androidx.appcompat.app.AppCompatActivity;

public class MainActivity extends AppCompatActivity {
    private TextView tvTitle;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        tvTitle = findViewById(R.id.tv_title);
        tvTitle.setText(weekLabel(0));
    }

    private String weekLabel(int offset) {
        return "第 " + (currentWeek() + offset) + " 周";
    }

    private int currentWeek() {
        return 3;
    }
}
JAVA

cat > "$WS/app/src/main/java/com/xwt/schedule/HolidayUtils.java" <<'JAVA'
package com.xwt.schedule;

import java.time.LocalDate;
import java.util.Map;

/** 法定节假日与调休判定。 */
public final class HolidayUtils {
    private static final Map<String, String> HOLIDAYS = Map.of(
        "2026-01-01", "元旦",
        "2026-10-01", "国庆节"
    );

    private HolidayUtils() {}

    public static boolean isHoliday(LocalDate date) {
        return HOLIDAYS.containsKey(date.toString());
    }

    public static String holidayName(LocalDate date) {
        return HOLIDAYS.get(date.toString());
    }
}
JAVA

cat > "$WS/app/src/main/res/layout/activity_main.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical">

    <TextView
        android:id="@+id/tv_title"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content" />
</LinearLayout>
XML

echo "演示工作区已生成: $WS"
find "$WS" -type f | sort
