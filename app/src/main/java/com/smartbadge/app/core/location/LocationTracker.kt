package com.smartbadge.app.core.location

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Looper
import com.smartbadge.app.domain.model.LocationPoint
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.Channel.Factory.UNLIMITED
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LocationTracker @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val locationManager: LocationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private val locationChannel = Channel<LocationPoint>(UNLIMITED)
    private var locationListener: LocationListener? = null

    @SuppressLint("MissingPermission")
    fun startTracking(): Flow<LocationPoint> {
        locationListener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                locationChannel.trySend(
                    LocationPoint(
                        latitude = location.latitude,
                        longitude = location.longitude,
                        timestamp = System.currentTimeMillis()
                    )
                )
            }

            override fun onProviderDisabled(provider: String) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onStatusChanged(provider: String, status: Int, extras: Bundle) {}
        }

        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        for (provider in providers) {
            try {
                locationManager.requestLocationUpdates(
                    provider,
                    5000L,     // minTimeMs
                    0f,        // minDistanceM
                    locationListener!!,
                    Looper.getMainLooper()
                )
            } catch (_: Exception) {
                // provider not available, try next
            }
        }

        return locationChannel.receiveAsFlow()
    }

    fun stopTracking() {
        locationListener?.let { locationManager.removeUpdates(it) }
        locationListener = null
    }
}
