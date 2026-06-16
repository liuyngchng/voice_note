# Hilt
-keep class dagger.hilt.** { *; }
-keep class javax.inject.** { *; }

# Room
-keep class com.smartbadge.app.core.database.** { *; }

# Gson
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.smartbadge.app.domain.model.** { *; }
