package com.antigravity.contactfinder.contact_finder

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.ContactsContract
import android.telecom.Call
import android.telecom.CallAudioState
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.Chronometer
import android.widget.GridLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView

class CallActivity : Activity(), SimpleInCallService.CallListener {

    private lateinit var tvAvatarInitials: TextView
    private lateinit var tvCallerName: TextView
    private lateinit var tvCallerNumber: TextView
    private lateinit var tvCallStatus: TextView
    private lateinit var chronometer: Chronometer

    private lateinit var layoutControls: LinearLayout
    private lateinit var btnSpeaker: ImageButton
    private lateinit var tvSpeakerLabel: TextView
    private lateinit var btnMute: ImageButton
    private lateinit var tvMuteLabel: TextView
    private lateinit var btnKeypad: ImageButton

    private lateinit var layoutActiveActions: LinearLayout
    private lateinit var btnEndCall: ImageButton

    private lateinit var layoutIncomingActions: LinearLayout
    private lateinit var btnDecline: ImageButton
    private lateinit var btnAnswer: ImageButton

    private lateinit var layoutDtmf: LinearLayout
    private lateinit var tvDtmfDigits: TextView
    private lateinit var gridDtmf: GridLayout
    private lateinit var btnHideDtmf: Button

    private var isSpeakerOn = false
    private var isMuted = false
    private var proximityWakeLock: PowerManager.WakeLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupLockScreenFlags()
        setContentView(R.layout.activity_call)

        initViews()
        setupDtmfGrid()
        setupListeners()
        setupProximitySensor()

        SimpleInCallService.callListener = this
        updateCallInfo()
    }

    private fun setupLockScreenFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            keyguardManager?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun setupProximitySensor() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (powerManager != null && powerManager.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                proximityWakeLock = powerManager.newWakeLock(
                    PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                    "DanhBaPro:CallProximity"
                )
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun initViews() {
        tvAvatarInitials = findViewById(R.id.tvAvatarInitials)
        tvCallerName = findViewById(R.id.tvCallerName)
        tvCallerNumber = findViewById(R.id.tvCallerNumber)
        tvCallStatus = findViewById(R.id.tvCallStatus)
        chronometer = findViewById(R.id.chronometer)

        layoutControls = findViewById(R.id.layoutControls)
        btnSpeaker = findViewById(R.id.btnSpeaker)
        tvSpeakerLabel = findViewById(R.id.tvSpeakerLabel)
        btnMute = findViewById(R.id.btnMute)
        tvMuteLabel = findViewById(R.id.tvMuteLabel)
        btnKeypad = findViewById(R.id.btnKeypad)

        layoutActiveActions = findViewById(R.id.layoutActiveActions)
        btnEndCall = findViewById(R.id.btnEndCall)

        layoutIncomingActions = findViewById(R.id.layoutIncomingActions)
        btnDecline = findViewById(R.id.btnDecline)
        btnAnswer = findViewById(R.id.btnAnswer)

        layoutDtmf = findViewById(R.id.layoutDtmf)
        tvDtmfDigits = findViewById(R.id.tvDtmfDigits)
        gridDtmf = findViewById(R.id.gridDtmf)
        btnHideDtmf = findViewById(R.id.btnHideDtmf)
    }

    private fun setupDtmfGrid() {
        val dtmfKeys = arrayOf(
            "1", "2", "3",
            "4", "5", "6",
            "7", "8", "9",
            "*", "0", "#"
        )

        gridDtmf.removeAllViews()
        val density = resources.displayMetrics.density
        val btnSize = (64 * density).toInt()
        val margin = (10 * density).toInt()

        for (key in dtmfKeys) {
            val btn = Button(this).apply {
                text = key
                textSize = 24f
                setTextColor(Color.WHITE)
                setBackgroundResource(R.drawable.bg_circle_btn)
                layoutParams = GridLayout.LayoutParams().apply {
                    width = btnSize
                    height = btnSize
                    setMargins(margin, margin, margin, margin)
                    setGravity(Gravity.CENTER)
                }
                setOnClickListener {
                    tvDtmfDigits.append(key)
                    SimpleInCallService.playDtmf(key[0])
                }
            }
            gridDtmf.addView(btn)
        }
    }

    private fun setupListeners() {
        btnEndCall.setOnClickListener {
            SimpleInCallService.endCall()
        }

        btnDecline.setOnClickListener {
            SimpleInCallService.declineCall()
        }

        btnAnswer.setOnClickListener {
            SimpleInCallService.answerCall()
        }

        btnSpeaker.setOnClickListener {
            isSpeakerOn = !isSpeakerOn
            SimpleInCallService.toggleSpeaker(isSpeakerOn)
            updateSpeakerUi()
        }

        btnMute.setOnClickListener {
            isMuted = !isMuted
            SimpleInCallService.toggleMute(isMuted)
            updateMuteUi()
        }

        btnKeypad.setOnClickListener {
            layoutDtmf.visibility = View.VISIBLE
        }

        btnHideDtmf.setOnClickListener {
            layoutDtmf.visibility = View.GONE
        }
    }

    private fun updateSpeakerUi() {
        if (isSpeakerOn) {
            btnSpeaker.setBackgroundResource(R.drawable.bg_circle_btn_active)
            btnSpeaker.setColorFilter(Color.parseColor("#0F172A"))
            tvSpeakerLabel.setTextColor(Color.parseColor("#38BDF8"))
            // Disable proximity when speaker is on
            if (proximityWakeLock?.isHeld == true) {
                proximityWakeLock?.release()
            }
        } else {
            btnSpeaker.setBackgroundResource(R.drawable.bg_circle_btn)
            btnSpeaker.setColorFilter(Color.WHITE)
            tvSpeakerLabel.setTextColor(Color.parseColor("#94A3B8"))
            // Re-acquire proximity when back to earpiece
            acquireProximityIfNeeded()
        }
    }

    private fun updateMuteUi() {
        if (isMuted) {
            btnMute.setBackgroundResource(R.drawable.bg_circle_btn_active)
            btnMute.setColorFilter(Color.parseColor("#EF4444"))
            tvMuteLabel.text = "Đã tắt mic"
            tvMuteLabel.setTextColor(Color.parseColor("#EF4444"))
        } else {
            btnMute.setBackgroundResource(R.drawable.bg_circle_btn)
            btnMute.setColorFilter(Color.WHITE)
            tvMuteLabel.text = "Tắt tiếng"
            tvMuteLabel.setTextColor(Color.parseColor("#94A3B8"))
        }
    }

    private fun acquireProximityIfNeeded() {
        val call = SimpleInCallService.currentCall
        if (call?.state == Call.STATE_ACTIVE && !isSpeakerOn) {
            if (proximityWakeLock?.isHeld != true) {
                try {
                    proximityWakeLock?.acquire(10 * 60 * 1000L /*10 mins*/)
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
    }

    private fun updateCallInfo() {
        val call = SimpleInCallService.currentCall
        if (call == null) {
            finish()
            return
        }

        val handle = call.details?.handle
        val rawNumber = handle?.schemeSpecificPart ?: ""
        val contactName = getContactName(rawNumber)

        if (!contactName.isNullOrEmpty()) {
            tvCallerName.text = contactName
            tvCallerNumber.text = rawNumber
            tvAvatarInitials.text = contactName.trim().firstOrNull()?.uppercase() ?: "?"
        } else {
            tvCallerName.text = if (rawNumber.isNotEmpty()) rawNumber else "Số không xác định"
            tvCallerNumber.text = "Danh bạ chưa lưu"
            tvAvatarInitials.text = "#"
        }

        onCallStateChanged(call.state)
    }

    override fun onCallStateChanged(state: Int) {
        mainHandler.post {
            when (state) {
                Call.STATE_RINGING -> {
                    tvCallStatus.visibility = View.VISIBLE
                    tvCallStatus.text = "Cuộc gọi đến..."
                    tvCallStatus.setTextColor(Color.parseColor("#22C55E"))
                    chronometer.visibility = View.GONE

                    layoutControls.visibility = View.GONE
                    layoutIncomingActions.visibility = View.VISIBLE
                    layoutActiveActions.visibility = View.GONE
                }
                Call.STATE_DIALING -> {
                    tvCallStatus.visibility = View.VISIBLE
                    tvCallStatus.text = "Đang gọi..."
                    tvCallStatus.setTextColor(Color.parseColor("#38BDF8"))
                    chronometer.visibility = View.GONE

                    layoutControls.visibility = View.VISIBLE
                    layoutIncomingActions.visibility = View.GONE
                    layoutActiveActions.visibility = View.VISIBLE
                }
                Call.STATE_CONNECTING -> {
                    tvCallStatus.visibility = View.VISIBLE
                    tvCallStatus.text = "Đang kết nối..."
                    tvCallStatus.setTextColor(Color.parseColor("#38BDF8"))
                    chronometer.visibility = View.GONE

                    layoutControls.visibility = View.VISIBLE
                    layoutIncomingActions.visibility = View.GONE
                    layoutActiveActions.visibility = View.VISIBLE
                }
                Call.STATE_ACTIVE -> {
                    tvCallStatus.visibility = View.GONE
                    chronometer.visibility = View.VISIBLE
                    chronometer.base = SystemClock.elapsedRealtime()
                    chronometer.start()

                    layoutControls.visibility = View.VISIBLE
                    layoutIncomingActions.visibility = View.GONE
                    layoutActiveActions.visibility = View.VISIBLE

                    acquireProximityIfNeeded()
                }
                Call.STATE_DISCONNECTED -> {
                    tvCallStatus.visibility = View.VISIBLE
                    tvCallStatus.text = "Cuộc gọi đã kết thúc"
                    tvCallStatus.setTextColor(Color.parseColor("#EF4444"))
                    chronometer.stop()

                    if (proximityWakeLock?.isHeld == true) {
                        try {
                            proximityWakeLock?.release()
                        } catch (e: Exception) {
                            e.printStackTrace()
                        }
                    }

                    mainHandler.postDelayed({
                        if (!isFinishing) {
                            finish()
                        }
                    }, 1200)
                }
            }
        }
    }

    override fun onCallAudioStateChanged(audioState: CallAudioState) {
        mainHandler.post {
            isSpeakerOn = (audioState.route == CallAudioState.ROUTE_SPEAKER)
            isMuted = audioState.isMuted
            updateSpeakerUi()
            updateMuteUi()
        }
    }

    private fun getContactName(phoneNumber: String): String? {
        if (phoneNumber.isEmpty()) return null
        return try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phoneNumber))
            val projection = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME)
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(ContactsContract.PhoneLookup.DISPLAY_NAME)
                    if (nameIdx >= 0) cursor.getString(nameIdx) else null
                } else null
            }
        } catch (e: Exception) {
            null
        }
    }

    override fun onDestroy() {
        if (proximityWakeLock?.isHeld == true) {
            try {
                proximityWakeLock?.release()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        if (SimpleInCallService.callListener == this) {
            SimpleInCallService.callListener = null
        }
        super.onDestroy()
    }
}
