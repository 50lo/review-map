import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension

plugins { kotlin("jvm") version "2.2.0" apply false }

// JVM 21, so a newer JDK running Gradle doesn't pick a target Kotlin can't emit.
subprojects {
    apply(plugin = "org.jetbrains.kotlin.jvm")
    repositories { mavenCentral() }
    extensions.configure<JavaPluginExtension> { targetCompatibility = JavaVersion.VERSION_21 }
    extensions.configure<KotlinJvmProjectExtension> { compilerOptions { jvmTarget.set(JvmTarget.JVM_21) } }
}
