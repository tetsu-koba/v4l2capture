#  V4L2 video capturer written in Zig

Capture MJPEG-format video from V4l2 camera device.

## How to Build and Use Sample Programs

```shell-session
$ zig version
0.11.0-dev.2696+867441845
$ zig build
$ ./zig-out/bin/v4l2capture 
Usage: ./zig-out/bin/v4l2capture /dev/videoX out.mjpg [width height framerate]
default is 640x480@30fps
```

```shell-session
$ ./zig-out/bin/v4l2capture /dev/video0 out.mjpg 320 240 30
warning: Requested format is 320x240 but set to 320x180.
^Cinfo: 1682150185282:Got SIGINT
info: 1682150185304:duration 24769ms, frame_count 743, 30.00fps
```
Stop the process by entering ^C at an appropriate point.
Although 320x240 was requested, the camera did not support it, so the message states that it has been changed to 320x180.

## Playing the Generated mjpg File

```shell-session
$ ffprobe out.mjpg

...

Input #0, jpeg_pipe, from 'out.mjpg':
  Duration: N/A, bitrate: N/A
    Stream #0:0: Video: mjpeg (Baseline), yuvj422p(pc, bt470bg/unknown/unknown), 320x180, 25 fps, 25 tbr, 25 tbn, 25 tbc
```

Although it shows 25fps here, this is incorrect. The default value for ffprobe when the frame rate is unknown is 25fps.
When playing this with ffplay, you need to explicitly specify the frame rate.

```shell-session
$ ffplay -framerate 30 out.mjpg
```

