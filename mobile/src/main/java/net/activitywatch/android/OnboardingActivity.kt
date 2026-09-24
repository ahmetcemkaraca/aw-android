package net.activitywatch.android

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.viewpager2.adapter.FragmentStateAdapter
import androidx.viewpager2.widget.ViewPager2
import com.google.android.material.tabs.TabLayout
import com.google.android.material.tabs.TabLayoutMediator
import net.activitywatch.android.watcher.MediaWatcher
import net.activitywatch.android.watcher.UsageStatsWatcher

// enum for the onboarding pages
enum class OnboardingPage {
    WELCOME,
    //FEATURES,
    ACCESSIBILITY_PERMISSION
}

class OnboardingActivity : AppCompatActivity() {
    private lateinit var viewPager: ViewPager2
    private lateinit var nextButton: Button
    private lateinit var backButton: Button
    private lateinit var preferences: AWPreferences
    private var updatingSourceSwitches = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_onboarding)

        viewPager = findViewById(R.id.viewPager)
        val tabLayout = findViewById<TabLayout>(R.id.tabLayout)
        viewPager.adapter = OnboardingAdapter(this)
        TabLayoutMediator(tabLayout, viewPager) { _, _ -> }.attach()

        nextButton = findViewById(R.id.nextButton)
        backButton = findViewById(R.id.backButton)
        preferences = AWPreferences(this)

        // If not users first time, skip to the last page
        if (!preferences.isFirstTime()) {
            viewPager.currentItem = OnboardingPage.ACCESSIBILITY_PERMISSION.ordinal
        }
        updateButtons()

        nextButton.setOnClickListener {
            val currentItem = viewPager.currentItem
            if (currentItem < OnboardingPage.entries.lastIndex) {
                viewPager.currentItem = currentItem + 1
            } else {
                finishSetup()
            }
            updateButtons()
        }

        backButton.setOnClickListener {
            val currentItem = viewPager.currentItem
            if (currentItem > 0) {
                viewPager.currentItem = currentItem - 1
            }
            updateButtons()
        }

        // Update the text of the next button based on the current page
        viewPager.registerOnPageChangeCallback(object : ViewPager2.OnPageChangeCallback() {
            override fun onPageSelected(position: Int) {
                updateButtons()
            }
        })

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                // If back button is pressed, exit the app,
                // since we don't want to allow the user to accidentally skip onboarding.
                // (Google Play policy, due to sensitive permissions)
                // https://developer.android.com/distribute/best-practices/develop/restrictions-non-sdk-interfaces#back-button
                finishAffinity()
            }
        })
    }

    override fun onResume() {
        super.onResume()
        if (::viewPager.isInitialized) updateButtons()
    }

    private fun updateButtons() {
        val lastPage = viewPager.currentItem == OnboardingPage.entries.lastIndex
        nextButton.text = when {
            !lastPage -> "Continue"
            !preferences.isFirstTime() -> "Done"
            UsageStatsWatcher.isUsageAllowed(this) -> "Start local recording"
            else -> "Continue in manual mode"
        }
        backButton.visibility = if (viewPager.currentItem > 0) View.VISIBLE else View.GONE
    }

    private fun finishSetup() {
        if (preferences.isFirstTime()) {
            // Reaching the explicit first-run action starts recording only if UsageStats was granted.
            preferences.setCaptureEnabled(UsageStatsWatcher.isUsageAllowed(this))
        }
        preferences.setFirstTimeRunFlag()
        startActivity(Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        })
        finish()
    }
}

class OnboardingAdapter(fragmentActivity: FragmentActivity) : FragmentStateAdapter(fragmentActivity) {

    override fun getItemCount(): Int = OnboardingPage.entries.size

    override fun createFragment(position: Int): Fragment {
        return when (position) {
            OnboardingPage.WELCOME.ordinal -> WelcomeFragment()
            //OnboardingPage.FEATURES.ordinal -> FeaturesFragment()
            OnboardingPage.ACCESSIBILITY_PERMISSION.ordinal -> PermissionsFragment()
            else -> throw IllegalArgumentException("Invalid position")
        }
    }
}


class WelcomeFragment : Fragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View? {
        return inflater.inflate(R.layout.fragment_welcome, container, false)
    }
}

class FeaturesFragment : Fragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View? {
        return inflater.inflate(R.layout.fragment_features, container, false)
    }
}


class PermissionsFragment : Fragment() {
    private var updatingSources = false

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        return inflater.inflate(R.layout.fragment_permissions, container, false)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        view.findViewById<Button>(R.id.btnGrantUsagePermission).setOnClickListener {
            confirmSource(
                title = R.string.usage_access_disclosure_title,
                message = R.string.usage_access_disclosure_message,
                accepted = { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) },
                declined = {},
            )
        }

        val preferences = AWPreferences(requireContext())
        val browserSwitch = view.findViewById<SwitchCompat>(R.id.switchBrowserCapture)
        val mediaSwitch = view.findViewById<SwitchCompat>(R.id.switchMediaCapture)
        browserSwitch.setOnCheckedChangeListener { _, enabled ->
            if (updatingSources) return@setOnCheckedChangeListener
            if (!enabled) {
                preferences.setBrowserCaptureEnabled(false)
                refreshPermissionIndicators(view, preferences)
            } else {
                confirmSource(
                    title = R.string.accessibility_disclosure_title,
                    message = R.string.accessibility_disclosure_message,
                    accepted = {
                        preferences.setBrowserCaptureEnabled(true)
                        refreshPermissionIndicators(view, preferences)
                        if (!UsageStatsWatcher.isAccessibilityAllowed(requireContext())) {
                            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        }
                    },
                    declined = { refreshPermissionIndicators(view, preferences) },
                )
            }
        }
        mediaSwitch.setOnCheckedChangeListener { _, enabled ->
            if (updatingSources) return@setOnCheckedChangeListener
            if (!enabled) {
                preferences.setMediaCaptureEnabled(false)
                MediaWatcher.requestRefresh(requireContext())
                refreshPermissionIndicators(view, preferences)
            } else {
                confirmSource(
                    title = R.string.media_access_disclosure_title,
                    message = R.string.media_access_disclosure_message,
                    accepted = {
                        preferences.setMediaCaptureEnabled(true)
                        refreshPermissionIndicators(view, preferences)
                        if (!MediaWatcher.isNotificationAccessGranted(requireContext())) {
                            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        } else {
                            MediaWatcher.requestRefresh(requireContext())
                        }
                    },
                    declined = { refreshPermissionIndicators(view, preferences) },
                )
            }
        }
        refreshPermissionIndicators(view, preferences)
    }

    private fun confirmSource(title: Int, message: Int, accepted: () -> Unit, declined: () -> Unit) {
        AlertDialog.Builder(requireContext())
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton(R.string.accessibility_disclosure_agree) { _, _ -> accepted() }
            .setNegativeButton(R.string.accessibility_disclosure_decline) { _, _ -> declined() }
            .show()
    }

    private fun refreshPermissionIndicators(view: View, preferences: AWPreferences) {
        val usageGranted = UsageStatsWatcher.isUsageAllowed(requireContext())
        val browserGranted = preferences.isBrowserCaptureEnabled() && UsageStatsWatcher.isAccessibilityAllowed(requireContext())
        val mediaGranted = preferences.isMediaCaptureEnabled() && MediaWatcher.isNotificationAccessGranted(requireContext())

        view.findViewById<ImageView>(R.id.checkmarkUsage)
            .setImageResource(if (usageGranted) R.drawable.ic_checkmark else R.drawable.ic_x)
        view.findViewById<ImageView>(R.id.checkmarkAccessibility)
            .setImageResource(if (browserGranted) R.drawable.ic_checkmark else R.drawable.ic_x)
        view.findViewById<ImageView>(R.id.checkmarkNotification)
            .setImageResource(if (mediaGranted) R.drawable.ic_checkmark else R.drawable.ic_x)

        updatingSources = true
        view.findViewById<SwitchCompat>(R.id.switchBrowserCapture).isChecked = preferences.isBrowserCaptureEnabled()
        view.findViewById<SwitchCompat>(R.id.switchMediaCapture).isChecked = preferences.isMediaCaptureEnabled()
        updatingSources = false
    }

    override fun onResume() {
        super.onResume()
        val currentView = view ?: return
        refreshPermissionIndicators(currentView, AWPreferences(requireContext()))
    }
}
