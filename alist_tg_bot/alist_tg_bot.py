import asyncio
import html
import logging
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

import requests
from pyrogram import Client, filters
from pyrogram.enums import ParseMode

from config import (
    ALIST_PASSWORD,
    ALIST_USERNAME,
    API_HASH,
    API_ID,
    BASE_URL,
    BOT_TOKEN,
    DST_DIR,
    FIXED_DOWNLOAD_DIR,
    GENERATE_GRID,
    GROUP_WHITELIST,
    MAX_CONCURRENT_DOWNLOADS,
    SESSION_NAME,
    SRC_DIR,
    UPLOAD_TO_ALIST,
    USER_WHITELIST,
)

# 日志和运行参数
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

HTTP_TIMEOUT = 30
PROGRESS_UPDATE_INTERVAL = 10
TASK_POLL_INTERVAL = 10
UPLOAD_SUCCESS_STATE = 2
UPLOAD_FAILED_STATE = 3


# 初始化 Telegram Bot 客户端和并发控制
app = Client(SESSION_NAME, api_id=API_ID, api_hash=API_HASH, bot_token=BOT_TOKEN)
semaphore = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)

os.makedirs(FIXED_DOWNLOAD_DIR, exist_ok=True)


# 权限和通用辅助函数
def is_authorized(message):
    user_allowed = message.from_user and message.from_user.id in USER_WHITELIST
    chat_allowed = message.chat and message.chat.id in GROUP_WHITELIST
    return user_allowed or chat_allowed


async def reply_no_permission(message, command=False):
    if command:
        text = "您没有权限使用该命令，请联系所有者以获取访问权限。"
    else:
        text = "您没有权限使用此功能，请联系所有者以获取访问权限。"
    await message.reply_text(text)


def get_current_time():
    return datetime.now().strftime("%H:%M:%S")


def make_html_video_name(file_name):
    return f"视频「<code>{html.escape(file_name)}</code>」"


def safe_remove(file_path):
    if not file_path:
        return

    try:
        Path(file_path).unlink(missing_ok=True)
    except OSError as error:
        logging.warning("Failed to delete %s: %s", file_path, error)


def sanitize_file_stem(name):
    safe_name = Path(name).name
    return safe_name or "telegram_video"


def request_json(method, url, **kwargs):
    kwargs.setdefault("timeout", HTTP_TIMEOUT)
    response = requests.request(method, url, **kwargs)
    response.raise_for_status()
    return response.json()


# Alist API 相关函数
def get_alist_token():
    response_data = request_json(
        "POST",
        f"{BASE_URL}/api/auth/login",
        json={"username": ALIST_USERNAME, "password": ALIST_PASSWORD},
        headers={"User-Agent": "alist-tg-bot"},
    )

    if response_data.get("code") != 200:
        message = response_data.get("message", "未知错误")
        raise RuntimeError(f"登录失败: {message}")

    return response_data["data"]["token"]


def copy_to_alist(token, source_dir, destination_dir, name):
    response_data = request_json(
        "POST",
        f"{BASE_URL}/api/fs/copy",
        json={"src_dir": source_dir, "dst_dir": destination_dir, "names": [name]},
        headers={"Authorization": token, "User-Agent": "alist-tg-bot"},
    )

    if response_data.get("code") != 200:
        logging.error("Failed to copy to Alist: %s", response_data.get("message", "未知错误"))
        return None

    tasks = response_data.get("data", {}).get("tasks", [])
    if not tasks:
        logging.error("Alist copy response has no task id: %s", response_data)
        return None

    task_id = tasks[0].get("id")
    logging.info("Successfully copied %s to Alist. Task ID: %s", name, task_id)
    return task_id


def get_task_state(token, task_id):
    try:
        response_data = request_json(
            "POST",
            f"{BASE_URL}/api/admin/task/copy/info?tid={task_id}",
            headers={"Authorization": token, "User-Agent": "alist-tg-bot"},
        )
        return response_data.get("data", {})
    except Exception as error:
        logging.error("Failed to get task state: %s", error)
        return {}


# ffmpeg / ffprobe 视频处理函数
def run_command(command):
    subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def get_command_output(command):
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return result.stdout.strip()


def is_portrait_mode(video_path):
    try:
        resolution = get_command_output([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=s=x:p=0", video_path,
        ])
        width, height = map(int, resolution.split("x"))
        return height > width
    except Exception as error:
        logging.error("Failed to get video resolution for %s: %s", video_path, error)
        return False


def get_video_duration(video_path):
    try:
        duration = get_command_output([
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", video_path,
        ])
        return float(duration)
    except Exception as error:
        logging.error("Failed to get video duration for %s: %s", video_path, error)
        return 0


def extract_frames(video_path, timestamps, completion_time):
    frame_images = []
    for index, timestamp in enumerate(timestamps):
        frame_image_path = os.path.join(FIXED_DOWNLOAD_DIR, f"{completion_time}_{index:03d}.png")
        run_command([
            "ffmpeg", "-y", "-ss", str(timestamp), "-i", video_path,
            "-vf", "scale=640:360", "-vframes", "1", frame_image_path,
        ])
        frame_images.append(frame_image_path)
    return frame_images


def create_grid_image(frame_images, completion_time, is_portrait):
    grid_image_path = os.path.join(FIXED_DOWNLOAD_DIR, f"{completion_time}.png")
    concat_file_path = os.path.join(FIXED_DOWNLOAD_DIR, f"{completion_time}_concat.txt")
    output_resolution = "1080x1920" if is_portrait else "1920x1080"

    with open(concat_file_path, "w", encoding="utf-8") as concat_file:
        for image_path in frame_images:
            concat_file.write(f"file '{image_path}'\n")

    run_command([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat_file_path,
        "-vf", f"tile=3x3,scale={output_resolution}", "-frames:v", "1", grid_image_path,
    ])

    return grid_image_path, concat_file_path


def build_timestamps(duration, count=9):
    if duration <= 0:
        return [0] * count
    return [duration * index / count for index in range(count)]


# 异步流程辅助函数
async def run_in_thread(function, *args):
    return await asyncio.to_thread(function, *args)


async def edit_upload_status(target_message, file_name, success):
    if success:
        text = f"{make_html_video_name(file_name)}已上传完成！"
    else:
        text = f"{make_html_video_name(file_name)}上传失败，详情请查看logs！"
    await target_message.edit_text(text, parse_mode=ParseMode.HTML)


async def wait_for_upload(token, task_id, target_message, file_name):
    while True:
        task_state = await run_in_thread(get_task_state, token, task_id)
        state = task_state.get("state", -1)

        if state == UPLOAD_SUCCESS_STATE:
            await edit_upload_status(target_message, file_name, success=True)
            return True

        if state == UPLOAD_FAILED_STATE:
            error_message = task_state.get("error", "未知错误")
            logging.error("Upload task %s failed. Error: %s", task_id, error_message)
            await edit_upload_status(target_message, file_name, success=False)
            return False

        logging.info("Upload task %s state is %s. Waiting for next check.", task_id, state)
        await asyncio.sleep(TASK_POLL_INTERVAL)


async def upload_to_alist(file_name, target_message):
    token = await run_in_thread(get_alist_token)
    task_id = await run_in_thread(copy_to_alist, token, SRC_DIR, DST_DIR, file_name)

    if not task_id:
        await edit_upload_status(target_message, file_name, success=False)
        return False

    return await wait_for_upload(token, task_id, target_message, file_name)


async def send_download_complete_message(message, status_message, grid_image_path, file_name):
    escaped_name = make_html_video_name(file_name)

    if UPLOAD_TO_ALIST:
        caption = f"{escaped_name}已下载完成，开始上传！"
    else:
        caption = f"{escaped_name}已下载完成！\n下载地址：{BASE_URL}{SRC_DIR}\n警告！文件将不定时清理！"

    if grid_image_path:
        grid_message = await message.reply_photo(photo=grid_image_path, caption=caption, parse_mode=ParseMode.HTML)
        await status_message.delete()
        return grid_message

    await status_message.edit_text(caption, parse_mode=ParseMode.HTML)
    return status_message


# 单个视频的完整处理流程
async def process_video(message):
    async with semaphore:
        status_message = None
        new_file_path = None
        grid_image_path = None
        concat_file_path = None
        frame_images = []

        try:
            video = message.video
            original_file_name = sanitize_file_stem(video.file_name or video.file_id)
            original_file_path = os.path.join(FIXED_DOWNLOAD_DIR, original_file_name)
            if not original_file_path.lower().endswith(".mp4"):
                original_file_path = f"{original_file_path}.mp4"

            # 发送初始状态消息，后续用于更新下载进度
            status_message = await message.reply_text(
                f"请稍后，视频正在下载中...\n当前下载进度：0.00%\n更新时间：{get_current_time()}"
            )

            # 限频更新进度，避免频繁编辑 Telegram 消息
            async def progress(current, total):
                if total <= 0:
                    return

                percentage = current * 100 / total
                if percentage >= 100:
                    return

                if time.time() - progress.last_update_time >= PROGRESS_UPDATE_INTERVAL:
                    progress.last_update_time = time.time()
                    await status_message.edit_text(
                        f"请稍后，视频正在下载中...\n当前下载进度：{percentage:.2f}%\n更新时间：{get_current_time()}"
                    )

            progress.last_update_time = time.time()
            await message.download(original_file_path, progress=progress)

            await status_message.edit_text(
                f"下载完成！正在生成图片！\n当前下载进度：100.00%\n更新时间：{get_current_time()}"
            )

            completion_time = datetime.now().strftime("%Y%m%d_%H%M%S")
            new_file_name = f"{completion_time}.mp4"
            new_file_path = os.path.join(FIXED_DOWNLOAD_DIR, new_file_name)
            os.replace(original_file_path, new_file_path)

            # 按配置生成九宫格预览图
            if GENERATE_GRID:
                is_portrait = await run_in_thread(is_portrait_mode, new_file_path)
                duration = await run_in_thread(get_video_duration, new_file_path)
                timestamps = build_timestamps(duration)
                frame_images = await run_in_thread(extract_frames, new_file_path, timestamps, completion_time)
                grid_image_path, concat_file_path = await run_in_thread(
                    create_grid_image, frame_images, completion_time, is_portrait
                )

            target_message = await send_download_complete_message(message, status_message, grid_image_path, new_file_name)

            # 按配置复制到 Alist，成功后删除本地视频
            if UPLOAD_TO_ALIST:
                await upload_to_alist(new_file_name, target_message)
                safe_remove(new_file_path)
            else:
                logging.info("Skipping Alist upload.")

        except Exception as error:
            logging.exception("Failed to process video: %s", error)
            if status_message:
                await status_message.edit_text("下载视频失败，详情请查看logs！")
        finally:
            # 无论成功或失败，都清理临时预览文件
            safe_remove(grid_image_path)
            safe_remove(concat_file_path)
            for frame_image in frame_images:
                safe_remove(frame_image)


# Telegram 消息入口
@app.on_message(filters.command("start"))
async def start_handler(client, message):
    if not is_authorized(message):
        await reply_no_permission(message, command=True)
        return

    await message.reply_text("请发送视频给我，我将帮您下载。")


@app.on_message(filters.command("dl"))
async def handle_dl_command(client, message):
    if not is_authorized(message):
        await reply_no_permission(message, command=True)
        return

    if not message.reply_to_message or not message.reply_to_message.video:
        await message.reply_text("请回复一条包含视频的消息。")
        return

    await process_video(message.reply_to_message)


@app.on_message(filters.video)
async def video_handler(client, message):
    if not is_authorized(message):
        await reply_no_permission(message)
        return

    await process_video(message)


# 启动 Bot
if __name__ == "__main__":
    app.run()
