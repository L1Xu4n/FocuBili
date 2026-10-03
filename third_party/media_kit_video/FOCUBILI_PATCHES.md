# FocuBili local changes (upstream media_kit_video 2.0.1, MIT)

Upstream source is from the pinned pub.dev 2.0.1 package. All existing platform
implementations are retained. Local Apple-only changes publish a bounded,
independent BGRA frame snapshot to an in-process native Picture in Picture
consumer when explicitly requested for the matching mpv handle. Original
Flutter texture buffers are never passed directly to AVSampleBufferDisplayLayer.
macOS synchronizes the current GL context only while this consumer is enabled.
See FocuBiliApplePictureInPicture.swift in packages/focubili_apple.
