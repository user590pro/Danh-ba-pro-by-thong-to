package com.antigravity.contactfinder.contact_finder

import android.content.Intent
import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.telecom.VideoProfile

class SimpleInCallService : InCallService() {

    companion object {
        var currentCall: Call? = null
        var inCallService: SimpleInCallService? = null
        var callListener: CallListener? = null

        fun answerCall() {
            currentCall?.answer(VideoProfile.STATE_AUDIO_ONLY)
        }

        fun declineCall() {
            if (currentCall?.state == Call.STATE_RINGING) {
                currentCall?.reject(false, null)
            } else {
                currentCall?.disconnect()
            }
        }

        fun endCall() {
            currentCall?.disconnect()
        }

        fun toggleSpeaker(on: Boolean) {
            val route = if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_EARPIECE
            inCallService?.setAudioRoute(route)
        }

        fun toggleMute(muted: Boolean) {
            inCallService?.setMuted(muted)
        }

        fun playDtmf(digit: Char) {
            try {
                currentCall?.playDtmfTone(digit)
                currentCall?.stopDtmfTone()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    interface CallListener {
        fun onCallStateChanged(state: Int)
        fun onCallAudioStateChanged(audioState: CallAudioState)
    }

    override fun onCallAdded(call: Call?) {
        super.onCallAdded(call)
        if (call == null) return

        currentCall = call
        inCallService = this

        call.registerCallback(object : Call.Callback() {
            override fun onStateChanged(c: Call?, state: Int) {
                super.onStateChanged(c, state)
                callListener?.onCallStateChanged(state)
            }
        })

        val intent = Intent(this, CallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        startActivity(intent)
    }

    override fun onCallRemoved(call: Call?) {
        super.onCallRemoved(call)
        if (currentCall == call) {
            callListener?.onCallStateChanged(Call.STATE_DISCONNECTED)
            currentCall = null
        }
    }

    override fun onCallAudioStateChanged(audioState: CallAudioState?) {
        super.onCallAudioStateChanged(audioState)
        audioState?.let {
            callListener?.onCallAudioStateChanged(it)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        inCallService = null
        currentCall = null
    }
}
