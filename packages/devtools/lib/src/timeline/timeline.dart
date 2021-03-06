// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:split/split.dart' as split;
import 'package:vm_service_lib/vm_service_lib.dart' hide TimelineEvent;

import '../framework/framework.dart';
import '../globals.dart';
import '../ui/analytics.dart' as ga;
import '../ui/analytics_platform.dart' as ga_platform;
import '../ui/elements.dart';
import '../ui/fake_flutter/dart_ui/dart_ui.dart';
import '../ui/icons.dart';
import '../ui/material_icons.dart';
import '../ui/primer.dart';
import '../ui/theme.dart';
import '../ui/ui_utils.dart';
import '../vm_service_wrapper.dart';
import 'event_details.dart';
import 'frame_flame_chart.dart';
import 'frames_bar_chart.dart';
import 'timeline_controller.dart';
import 'timeline_protocol.dart';

// Light mode is Light Blue 50 palette and Dark mode is Blue 50 palette.
// https://material.io/design/color/the-color-system.html#tools-for-picking-colors.
const mainUiColorLight = Color(0xFF81D4FA); // Light Blue 50 - 200
const mainUiColorSelectedLight = Color(0xFFD4D7DA); // Lighter grey.

const mainGpuColorLight = Color(0xFF0288D1); // Light Blue 50 - 700
const mainGpuColorSelectedLight = Color(0xFFB5B5B5); // Darker grey.

const mainUiColorDark = Color(0xFF9EBEF9); // Blue 200 Material Dark
const mainUiColorSelectedDark = Colors.white;

const mainGpuColorDark = Color(0xFF1A73E8); // Blue 600 Material Dark
const mainGpuColorSelectedDark = Color(0xFFC9C9C9); // Grey.

const mainUiColor = ThemedColor(mainUiColorLight, mainUiColorDark);
const mainGpuColor = ThemedColor(mainGpuColorLight, mainGpuColorDark);

const Color selectedUiColor =
    ThemedColor(mainUiColorSelectedLight, mainUiColorSelectedDark);
const Color selectedGpuColor =
    ThemedColor(mainGpuColorSelectedLight, mainGpuColorSelectedDark);

// Light is Red @ .2 opacity, Dark is Red 200 Material Dark @ .2 opacity.
const Color jankGlowInside = ThemedColor(Color(0x66FF0000), Color(0x66F29C99));
// Light is Red @ .5 opacity, Dark is Red 600 Material Dark @ .6 opacity.
const Color jankGlowEdge = ThemedColor(Color(0x80FF0000), Color(0x99CE191C));

// Red 50 - 400 is light at 1/2 opacity, Dark Red 500 Material Dark.
const Color highwater16msColor = mainUiColorSelectedLight;

const Color hoverTextHighContrastColor = Colors.white;
const Color hoverTextColor = Colors.black;

// Matches our default button colors for light and dark theme.
const exportTimelineButtonColor = ThemedColor(
  Color(0xFF24292E),
  Color(0xFF89B5F8),
);

const Icon exportTimeline = MaterialIcon(
  'file_download',
  exportTimelineButtonColor,
  fontSize: 32,
  iconWidth: 18,
);

// TODO(devoncarew): show the Skia picture (gpu drawing commands) for a frame

// TODO(devoncarew): show the list of widgets re-drawn during a frame

// TODO(devoncarew): display whether running in debug or profile

// TODO(devoncarew): Have a timeline view thumbnail overview.

// TODO(devoncarew): Switch to showing all timeline events, but highlighting the
// area associated with the selected frame.

const Icon _clear = MaterialIcon('block', defaultButtonIconColor);

class TimelineScreen extends Screen {
  TimelineScreen({bool disabled, String disabledTooltip})
      : super(
          name: 'Timeline',
          id: 'timeline',
          iconClass: 'octicon-pulse',
          disabled: disabled,
          disabledTooltip: disabledTooltip,
        );

  TimelineController timelineController = TimelineController();

  FramesBarChart framesBarChart;

  FrameFlameChart flameChart;

  EventDetails eventDetails;

  bool _paused = false;

  PButton pauseButton;
  PButton resumeButton;
  CoreElement upperButtonSection;
  CoreElement debugButtonSection;

  @override
  CoreElement createContent(Framework framework) {
    ga_platform.setupDimensions();

    final CoreElement screenDiv = div()..layoutVertical();

    bool splitterConfigured = false;

    pauseButton = PButton.icon('Pause recording', FlutterIcons.pause_white_2x)
      ..small()
      ..primary()
      ..click(_pauseRecording);

    resumeButton =
        PButton.icon('Resume recording', FlutterIcons.resume_black_disabled_2x)
          ..small()
          ..clazz('margin-left')
          ..disabled = true
          ..click(_resumeRecording);

    upperButtonSection = div(c: 'section')
      ..layoutHorizontal()
      ..add(<CoreElement>[
        div(c: 'btn-group')
          ..add([
            pauseButton,
            resumeButton,
          ]),
        PButton.icon('Clear', _clear)
          ..small()
          ..clazz('margin-left')
          ..setAttribute('title', 'Clear timeline')
          ..click(_clearTimeline),
        div()..flex(),
        debugButtonSection = div(c: 'btn-group'),
        PButton.icon('', exportTimeline)
          ..small()
          ..clazz('margin-left')
          ..setAttribute('title', 'Export timeline')
          ..click(_exportTimeline),
      ]);

    _maybeAddDebugButtons();

    screenDiv.add(<CoreElement>[
      upperButtonSection,
      div(c: 'section section-border')
        ..add(framesBarChart = FramesBarChart(timelineController)),
      div(c: 'section')
        ..layoutVertical()
        ..flex()
        ..add(<CoreElement>[
          flameChart = FrameFlameChart()..attribute('hidden'),
          eventDetails = EventDetails()..attribute('hidden'),
        ]),
    ]);

    serviceManager.onConnectionAvailable.listen(_handleConnectionStart);
    if (serviceManager.hasConnection) {
      _handleConnectionStart(serviceManager.service);
    }
    serviceManager.onConnectionClosed.listen(_handleConnectionStop);

    framesBarChart.onSelectedFrame.listen((TimelineFrame frame) {
      if (frame != null && timelineController.hasStarted) {
        flameChart.attribute('hidden', frame == null);
        eventDetails.attribute('hidden', frame == null);

        if (debugTimeline && frame != null) {
          final buf = StringBuffer();
          buf.writeln('UI timeline event for frame ${frame.id}:');
          frame.uiEventFlow.format(buf, '  ');
          buf.writeln('\nUI trace for frame ${frame.id}');
          frame.uiEventFlow.writeTraceToBuffer(buf);
          buf.writeln('\nGPU timeline event frame ${frame.id}:');
          frame.gpuEventFlow.format(buf, '  ');
          buf.writeln('\nGPU trace for frame ${frame.id}');
          frame.gpuEventFlow.writeTraceToBuffer(buf);
          print(buf.toString());
        }

        flameChart.update(frame);
        eventDetails.reset();

        // Configure the flame chart / event details splitter if we haven't
        // already.
        if (!splitterConfigured) {
          split.flexSplit(
            [flameChart.element, eventDetails.element],
            horizontal: false,
            gutterSize: defaultSplitterWidth,
            sizes: [75, 25],
            minSize: [60, 160],
          );
          splitterConfigured = true;
        }
      }
    });

    onSelectedFrameFlameChartItem.listen((FrameFlameChartItem item) async {
      final TimelineEvent event = item.event;
      ga.select(
        ga.timeline,
        event.isGpuEvent ? ga.timelineFlameGpu : ga.timelineFlameUi,
        event.time.duration.inMicroseconds, // No inMilliseconds loses precision
      );

      await eventDetails.update(item);
    });

    maybeShowDebugWarning(framework);

    return screenDiv;
  }

  @override
  void entering() {
    _updateListeningState();
  }

  @override
  void exiting() {
    framework.clearMessages();
    _updateListeningState();
  }

  void _handleConnectionStart(VmServiceWrapper service) {
    serviceManager.service.setFlag('profile_period', '50');
    serviceManager.service.onEvent('Timeline').listen((Event event) {
      final List<dynamic> list = event.json['timelineEvents'];
      final List<Map<String, dynamic>> events =
          list.cast<Map<String, dynamic>>();

      for (Map<String, dynamic> json in events) {
        final TraceEvent e = TraceEvent(json);
        timelineController.timelineData?.processTraceEvent(e);
      }
    });
  }

  void _handleConnectionStop(dynamic event) {
    timelineController = null;
  }

  void _pauseRecording() {
    ga.select(ga.timeline, ga.pause);

    _updateButtons(paused: true);
    _paused = true;
    _updateListeningState();
  }

  void _resumeRecording() {
    ga.select(ga.timeline, ga.resume);
    _updateButtons(paused: false);
    _paused = false;
    _updateListeningState();
  }

  void _updateButtons({@required bool paused}) {
    pauseButton.disabled = paused;
    resumeButton.disabled = !paused;
  }

  void _updateListeningState() async {
    await serviceManager.serviceAvailable.future;

    final bool shouldBeRunning = !_paused && isCurrentScreen;
    final bool isRunning = !timelineController.paused;

    if (shouldBeRunning && isRunning && !timelineController.hasStarted) {
      await timelineController.startTimeline();
    }

    if (shouldBeRunning && !isRunning) {
      timelineController.resume();

      await serviceManager.service
          .setVMTimelineFlags(<String>['GC', 'Dart', 'Embedder']);
    } else if (!shouldBeRunning && isRunning) {
      // TODO(devoncarew): turn off the events
      await serviceManager.service.setVMTimelineFlags(<String>[]);
      timelineController.pause();
    }
  }

  void _clearTimeline() {
    framesBarChart.frameUIgraph.reset();
    flameChart.attribute('hidden', true);
    eventDetails.attribute('hidden', true);
    eventDetails.reset();
  }

  void _exportTimeline() {
    // TODO(kenzie): add analytics for this. It would be helpful to know how
    // complex the problems are that users are trying to solve.
    final Map<String, dynamic> json = {
      'traceEvents': timelineTraceEvents,
      'cpuProfile': eventDetails.cpuProfileData != null
          ? eventDetails.cpuProfileData.cpuProfileResponse.json
          : {},
    };
    final now = DateTime.now();
    final timestamp =
        '${now.year}_${now.month}_${now.day}-${now.microsecondsSinceEpoch}';
    downloadFile(jsonEncode(json), 'timeline_$timestamp.json');
  }

  /// Adds a button to the timeline that will dump debug information to text
  /// files and download them. This will only appear if the [debugTimeline] flag
  /// is true.
  void _maybeAddDebugButtons() {
    if (debugTimeline) {
      debugButtonSection.add(PButton('Debug dump timeline')
        ..small()
        ..click(() {
          // Trace event json in the order we handled the events.
          final handledTraceEventsJson = {
            'traceEvents': debugHandledTraceEvents
          };
          downloadFile(
            jsonEncode(handledTraceEventsJson),
            'handled_trace_output.json',
          );

          // Significant events in the frame tracking process.
          downloadFile(
            debugFrameTracking.toString(),
            'frame_tracking_output.txt',
          );

          // Current status of our frame tracking elements (i.e. pendingEvents,
          // pendingFrames).
          final buf = StringBuffer();
          buf.writeln('Pending events: '
              '${timelineController.timelineData.pendingEvents.length}');
          for (TimelineEvent event
              in timelineController.timelineData.pendingEvents) {
            event.format(buf, '    ');
            buf.writeln();
          }
          buf.writeln('\nPending frames: '
              '${timelineController.timelineData.pendingFrames.length}');
          for (TimelineFrame frame
              in timelineController.timelineData.pendingFrames.values) {
            buf.writeln('${frame.toString()}');
          }
          if (timelineController
                  .timelineData.currentEventNodes[TimelineEventType.ui.index] !=
              null) {
            buf.writeln('\nCurrent UI event node:');
            timelineController
                .timelineData.currentEventNodes[TimelineEventType.ui.index]
                .format(buf, '   ');
          }
          if (timelineController.timelineData
                  .currentEventNodes[TimelineEventType.gpu.index] !=
              null) {
            buf.writeln('\n Current GPU event node:');
            timelineController
                .timelineData.currentEventNodes[TimelineEventType.gpu.index]
                .format(buf, '   ');
          }
          if (timelineController
              .timelineData.heaps[TimelineEventType.ui.index].isNotEmpty) {
            buf.writeln('\nUI heap');
            for (TraceEventWrapper wrapper in timelineController
                .timelineData.heaps[TimelineEventType.ui.index]
                .toList()) {
              buf.writeln(wrapper.event.json.toString());
            }
          }
          if (timelineController
              .timelineData.heaps[TimelineEventType.gpu.index].isNotEmpty) {
            buf.writeln('\nGPU heap');
            for (TraceEventWrapper wrapper in timelineController
                .timelineData.heaps[TimelineEventType.gpu.index]
                .toList()) {
              buf.writeln(wrapper.event.json.toString());
            }
          }
          downloadFile(buf.toString(), 'pending_frame_tracking_status.txt');
        }));
    }
  }
}
