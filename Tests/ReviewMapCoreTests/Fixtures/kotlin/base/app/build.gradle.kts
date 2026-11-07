plugins { kotlin("android") version "2.2.0" }
dependencies {
    implementation(project(":core"))
    implementation("androidx.compose.runtime:runtime:1.9.0")
    testImplementation("junit:junit:4.13.2")
}
