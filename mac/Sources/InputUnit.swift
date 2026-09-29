// One sound card, opened for capture.
//
// The microphone and every extra source open a device the same way, so they
// open it through here rather than each keeping its own copy of the AUHAL
// dance. Duplicating a capture path is exactly where a bug hides: one copy
// gets the channel count fix and the other does not.
//
// This class does nothing to the audio. It hands the raw interleaved frames to
// its owner at whatever rate and channel count the device really offers, and
// the owner decides what that means.

import Foundation
import AudioToolbox
import CoreAudio

final class InputUnit {

    /// Called on the audio thread. Interleaved, `channels` wide, at
    /// `captureRate`. Must not block and must not throw.
    var onCapture: ((UnsafePointer<Float>, Int, UInt32) -> Void)?

    private(set) var captureRate: Double = C.defaultSampleRate
    private(set) var channels: UInt32 = 2
    private(set) var isOpen = false
    private(set) var lastError: String?
    /// The device this unit really has open. Written only once an opening
    /// has SUCCEEDED (N9, W383-11): it used to be written before the first
    /// call to Core Audio, so a failed opening left a name behind that the
    /// microphone key then reported, and saved, as the one in use.
    private(set) var deviceUID: String?
    private(set) var deviceName: String?
    /// The last OSStatus an opening got back, for `MicDiag.explain` and for a
    /// feedback report. nil after a success, and nil when there was no device
    /// to open at all.
    private(set) var lastStatus: OSStatus?

    /// Counted on the audio thread, read on the main one a moment after
    /// opening (W383-10). Plain counters: a torn read of one of these is at
    /// worst a check that runs again at the next opening.
    ///
    /// Which opening this is, so a check scheduled for one opening never
    /// reports on the next.
    private(set) var openings = 0
    /// Capture callbacks that arrived since the last opening.
    private(set) var blocksSeen = 0
    /// Callbacks where the render itself failed, which used to be dropped
    /// without a trace (N8).
    private(set) var failedReads = 0
    private(set) var lastReadStatus: OSStatus = noErr
    /// Any raw sample other than exact zero since the last opening, measured
    /// BEFORE any gain.
    private(set) var signalSeen = false

    private var unit: AudioUnit?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var raw: UnsafeMutablePointer<Float>
    private var capacity = 8192

    init() { raw = .allocate(capacity: capacity * 4) }

    deinit { close(); raw.deallocate() }

    /// Open a specific device, or the system default input when uid is nil.
    @discardableResult
    func open(deviceUID uid: String?) -> Bool {
        guard !isOpen else { return true }
        lastError = nil
        lastStatus = nil

        guard var deviceID = uid.flatMap(AudioDevices.deviceID(forUID:))
                ?? AudioDevices.defaultInput() else {
            lastError = "There is no input device on this Mac"
            return false
        }
        // Read now, written only on success, at the end.
        let openingUID = AudioDevices.info(for: deviceID)?.uid ?? uid
        let openingName = AudioDevices.info(for: deviceID)?.name

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            lastError = "No audio input unit on this system"
            return false
        }
        var u: AudioUnit?
        let made = AudioComponentInstanceNew(comp, &u)
        guard made == noErr, let unit = u else {
            lastError = "Could not open that input"
            lastStatus = made == noErr ? kAudioHardwareUnspecifiedError : made
            return false
        }

        // Every step keeps what Core Audio said, so the reason a person hears
        // is the real one (W383-07) rather than a fixed phrase.
        var status: OSStatus = noErr
        func fail(_ message: String) -> Bool {
            lastError = message
            lastStatus = status == noErr ? kAudioHardwareUnspecifiedError : status
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            return false
        }
        func ok(_ result: OSStatus) -> Bool {
            status = result
            return result == noErr
        }

        // Input on element 1, output off on element 0. An AUHAL that is not
        // told this captures nothing at all, silently.
        var on: UInt32 = 1, off: UInt32 = 0
        guard ok(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &on,
                                      UInt32(MemoryLayout<UInt32>.size))),
              ok(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &off,
                                      UInt32(MemoryLayout<UInt32>.size)))
        else { return fail("That input would not open for capture") }

        guard ok(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceID,
                                      UInt32(MemoryLayout<AudioDeviceID>.size)))
        else { return fail("That input would not open") }

        // Take the rate the device really offers and convert afterwards. Asking
        // for a rate a device does not have is simply refused, and a working
        // input at the wrong rate beats no input at all.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 1, &hardware, &size)
        captureRate = hardware.mSampleRate > 0 ? hardware.mSampleRate : C.defaultSampleRate
        channels = max(1, min(2, hardware.mChannelsPerFrame))

        var format = AudioStreamBasicDescription(
            mSampleRate: captureRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)
        guard ok(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1, &format,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        else { return fail("That input would not give float audio") }

        var callback = AURenderCallbackStruct(
            inputProc: inputUnitCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard ok(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 0, &callback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        else { return fail("The capture callback would not attach") }

        guard ok(AudioUnitInitialize(unit)) else {
            return fail("That input would not start")
        }

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0].mNumberChannels = channels
        list[0].mDataByteSize = 0
        list[0].mData = nil
        bufferList = list

        // Counted from zero for this opening BEFORE it starts, so the first
        // callback is never lost to a reset that lands after it.
        blocksSeen = 0
        failedReads = 0
        lastReadStatus = noErr
        signalSeen = false
        guard ok(AudioOutputUnitStart(unit)) else {
            AudioUnitUninitialize(unit)
            if let l = bufferList { free(l.unsafeMutablePointer) }
            bufferList = nil
            return fail("That input would not start")
        }

        self.unit = unit
        deviceUID = openingUID
        deviceName = openingName
        openings += 1
        isOpen = true
        return true
    }

    func close() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        if let list = bufferList { free(list.unsafeMutablePointer) }
        bufferList = nil
        isOpen = false
    }

    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32) {
        guard let unit, let list = bufferList else { return }
        let n = Int(frames)
        if n > capacity {
            raw.deallocate()
            capacity = n * 2
            raw = .allocate(capacity: capacity * 4)
        }
        list[0].mNumberChannels = channels
        list[0].mDataByteSize = UInt32(n * Int(channels) * 4)
        list[0].mData = UnsafeMutableRawPointer(raw)
        blocksSeen += 1
        let rendered = AudioUnitRender(unit, flags, timestamp, bus, frames,
                                       list.unsafeMutablePointer)
        guard rendered == noErr else {
            // Counted rather than dropped in silence (N8): a microphone whose
            // every read fails sends nothing, and this is how that is told
            // apart from one that is simply quiet.
            failedReads += 1
            lastReadStatus = rendered
            return
        }
        if !signalSeen, MicDiag.hasSignal(raw, count: n * Int(channels)) { signalSeen = true }
        onCapture?(raw, n, channels)
    }
}

private func inputUnitCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let unit = Unmanaged<InputUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    unit.render(flags: ioActionFlags, timestamp: inTimeStamp,
                bus: inBusNumber, frames: inNumberFrames)
    return noErr
}

/// Fold a captured block down to interleaved stereo, applying the channel
/// choice and the gain, and report the peak.
///
/// "Mixed" AVERAGES rather than sums, so choosing it never makes a centred
/// voice six decibels louder than choosing a side.
@discardableResult
func foldToStereo(_ raw: UnsafePointer<Float>, frames: Int, channels: UInt32,
                  channel: MicChannel, gain: Float,
                  into out: UnsafeMutablePointer<Float>) -> Float {
    var loudest: Float = 0
    if channels >= 2 {
        // Step by the REAL channel count, not by two. A capture with more than
        // two channels, which an aggregate device clocked by a multi channel
        // interface will hand over, would otherwise be read as interleaved
        // stereo and come out as noise. For two channels this is the same
        // arithmetic it always was.
        let step = Int(channels)
        // Stereo is kept, not folded. Everything else lands in both ears,
        // because that is what a mono voice needs.
        if channel == .stereo {
            for i in 0..<frames {
                let l = raw[i * step] * gain, r = raw[i * step + 1] * gain
                loudest = max(loudest, max(abs(l), abs(r)))
                out[i * 2] = l
                out[i * 2 + 1] = r
            }
            return loudest
        }
        for i in 0..<frames {
            let v: Float
            switch channel {
            case .left: v = raw[i * step]
            case .right: v = raw[i * step + 1]
            default:
                var sum: Float = 0
                for c in 0..<step { sum += raw[i * step + c] }
                v = sum / Float(step)
            }
            let scaled = v * gain
            loudest = max(loudest, abs(scaled))
            out[i * 2] = scaled
            out[i * 2 + 1] = scaled
        }
    } else {
        for i in 0..<frames {
            let scaled = raw[i] * gain
            loudest = max(loudest, abs(scaled))
            out[i * 2] = scaled
            out[i * 2 + 1] = scaled
        }
    }
    return loudest
}
