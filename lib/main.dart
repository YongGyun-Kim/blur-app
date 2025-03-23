import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:gallery_saver/gallery_saver.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Region Blur Video App',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: VideoPlayerScreen(),
    );
  }
}

class VideoPlayerScreen extends StatefulWidget {
  @override
  _VideoPlayerScreenState createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  final ImagePicker _picker = ImagePicker();
  String? _videoPath;

  // 선택 영역(위젯 좌표 기준)
  Rect? selectionRect;
  Offset? dragStart;

  // 영상 위젯의 크기를 가져오기 위한 GlobalKey
  final GlobalKey _videoContainerKey = GlobalKey();

  /// 갤러리에서 영상을 선택하고 VideoPlayerController를 초기화
  Future<void> _pickVideo() async {
    final XFile? videoFile = await _picker.pickVideo(
      source: ImageSource.gallery,
    );
    if (videoFile != null) {
      _videoPath = videoFile.path;
      _controller?.dispose();
      _controller = VideoPlayerController.file(File(_videoPath!))
        ..initialize().then((_) {
          setState(() {
            selectionRect = null; // 이전 선택 영역 초기화
          });
          _controller?.play();
        });
    }
  }

  /// 선택 영역(위젯 좌표)을 실제 영상의 픽셀 좌표로 변환
  Rect _convertSelectionRect(Size displayedSize, Size videoSize) {
    double scaleX = videoSize.width / displayedSize.width;
    double scaleY = videoSize.height / displayedSize.height;
    return Rect.fromLTWH(
      selectionRect!.left * scaleX,
      selectionRect!.top * scaleY,
      selectionRect!.width * scaleX,
      selectionRect!.height * scaleY,
    );
  }

  /// 사용자가 선택한 영역에만 블러 처리하고, 출력 영상의 생성 시간을 현재 시간으로 설정
  Future<void> _applyBlur() async {
    if (_videoPath == null) return;
    if (selectionRect == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('먼저 영상 위에서 영역을 선택하세요.')));
      return;
    }

    // 영상 위젯의 실제 표시 크기를 가져옴
    final RenderBox? renderBox =
        _videoContainerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('영상 영역 크기를 가져올 수 없습니다.')));
      return;
    }
    final displayedSize = renderBox.size;
    final videoSize = _controller!.value.size;
    final Rect actualRect = _convertSelectionRect(displayedSize, videoSize);
    final int selX = actualRect.left.toInt();
    final int selY = actualRect.top.toInt();
    final int selWidth = actualRect.width.toInt();
    final int selHeight = actualRect.height.toInt();

    // 임시 디렉토리 내 결과 파일 경로
    final Directory tempDir = Directory.systemTemp;
    final String outputPath = '${tempDir.path}/output_blur.mp4';

    // 현재 UTC 시간을 ISO 8601 형식으로 생성 (예: "2025-03-21T12:34:56Z")
    final String now = DateTime.now().toUtc().toIso8601String();
    final int videoWidth = videoSize.width.toInt();
    final int videoHeight = videoSize.height.toInt();

    // FFmpeg 명령어:
    // - 원본 영상([base])를 그대로 사용하고,
    // - [copy] 스트림에서 선택 영역을 crop한 후 gblur를 적용한 [blurred] 스트림을 overlay
    // - overlay 후 scale=iw:ih로 해상도를 원본과 동일하게 강제
    // - 하드웨어 인코더 h264_videotoolbox를 사용하고, 생성 시간을 메타데이터에 지정
    String command =
        '-y -i $_videoPath -filter_complex "[0:v]split=2[base][copy];'
        '[copy]crop=w=$selWidth:h=$selHeight:x=$selX:y=$selY, gblur=sigma=10[blurred];'
        '[base][blurred]overlay=x=$selX:y=$selY,scale=$videoWidth:$videoHeight" '
        '-c:v h264_videotoolbox -b:v 8000k -metadata creation_time="$now" '
        '-c:a copy $outputPath';

    print('FFmpeg command: $command');

    await FFmpegKit.execute(command).then((session) async {
      final returnCode = await session.getReturnCode();
      print('FFmpeg return code: $returnCode');
      if (returnCode!.isValueSuccess()) {
        final outputFile = File(outputPath);
        if (await outputFile.exists()) {
          print('FFmpeg 작업 완료. 출력 파일: $outputPath');
          print('Output file size: ${await outputFile.length()} bytes');

          // 결과 영상 앨범에 저장
          bool? saveResult = await GallerySaver.saveVideo(outputPath);
          if (saveResult == true) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('영상이 앨범에 저장되었습니다.')));
          } else {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('영상 저장에 실패했습니다.')));
          }
          // 결과 파일로 재생하도록 VideoPlayerController 재설정
          _videoPath = outputPath;
          _controller?.dispose();
          _controller = VideoPlayerController.file(File(_videoPath!))
            ..initialize().then((_) {
              setState(() {
                selectionRect = null; // 선택 영역 초기화
              });
              _controller?.play();
            });
        } else {
          print('출력 파일이 존재하지 않습니다.');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('출력 파일 생성 실패.')));
        }
      } else {
        print('FFmpeg 작업 실패.');
        final logs = await session.getAllLogsAsString();
        print('FFmpeg logs: $logs');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('FFmpeg 작업 실패.')));
      }
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // 선택 영역을 그리기 위한 CustomPainter
  Widget _buildSelectionOverlay() {
    return CustomPaint(
      painter: SelectionPainter(rect: selectionRect),
      child: Container(),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget videoArea;
    if (_controller != null && _controller!.value.isInitialized) {
      // GlobalKey를 할당한 Container로 영상 위젯 감싸기
      videoArea = Container(
        key: _videoContainerKey,
        child: AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: VideoPlayer(_controller!),
        ),
      );
    } else {
      videoArea = Container(
        height: 200,
        color: Colors.black12,
        child: Center(child: Text('No video selected')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('Region Blur Video App')),
      body: SingleChildScrollView(
        child: Center(
          child: Column(
            children: [
              // Stack: 영상, 선택 영역 오버레이, 그리고 GestureDetector
              Stack(
                children: [
                  videoArea,
                  Positioned.fill(
                    child: GestureDetector(
                      onPanStart: (details) {
                        setState(() {
                          final localPos = details.localPosition;
                          dragStart = localPos;
                          selectionRect = Rect.fromLTWH(
                            localPos.dx,
                            localPos.dy,
                            0,
                            0,
                          );
                        });
                      },
                      onPanUpdate: (details) {
                        setState(() {
                          final currentPos = details.localPosition;
                          if (dragStart != null) {
                            double left = dragStart!.dx;
                            double top = dragStart!.dy;
                            double width = currentPos.dx - dragStart!.dx;
                            double height = currentPos.dy - dragStart!.dy;
                            if (width < 0) {
                              left = currentPos.dx;
                              width = -width;
                            }
                            if (height < 0) {
                              top = currentPos.dy;
                              height = -height;
                            }
                            selectionRect = Rect.fromLTWH(
                              left,
                              top,
                              width,
                              height,
                            );
                          }
                        });
                      },
                      onPanEnd: (details) {
                        setState(() {
                          dragStart = null;
                        });
                      },
                      child: _buildSelectionOverlay(),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: _pickVideo,
                child: Text('Select Video'),
              ),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: _applyBlur,
                child: Text('Apply Blur to Selected Region'),
              ),
              SizedBox(height: 20),
              if (_controller != null && _controller!.value.isInitialized)
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _controller!.value.isPlaying
                          ? _controller!.pause()
                          : _controller!.play();
                    });
                  },
                  child: Icon(
                    _controller!.value.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SelectionPainter extends CustomPainter {
  final Rect? rect;
  SelectionPainter({this.rect});

  @override
  void paint(Canvas canvas, Size size) {
    if (rect != null) {
      final paint =
          Paint()
            ..color = Colors.blue.withOpacity(0.3)
            ..style = PaintingStyle.fill;
      final border =
          Paint()
            ..color = Colors.blue
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke;
      canvas.drawRect(rect!, paint);
      canvas.drawRect(rect!, border);
    }
  }

  @override
  bool shouldRepaint(covariant SelectionPainter oldDelegate) {
    return oldDelegate.rect != rect;
  }
}
