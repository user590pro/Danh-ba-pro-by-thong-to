package com.antigravity.contactfinder.contact_finder

import android.telecom.Call
import android.telecom.InCallService

class SimpleInCallService : InCallService() {
    override fun onCallAdded(call: Call?) {
        super.onCallAdded(call)
    }

    override fun onCallRemoved(call: Call?) {
        super.onCallRemoved(call)
    }
}
