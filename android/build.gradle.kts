plugins {
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.2" apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Flutter's app module configures itself from the Flutter plugin; evaluating it
// eagerly is what keeps plugin subprojects consistent. :app and :streamcore are
// excluded because :app now depends on :streamcore (a cycle), and :app
// evaluating itself is a no-op at best.
subprojects {
    if (name != "app" && name != "streamcore") {
        project.evaluationDependsOn(":app")
    }
}

subprojects {
    if (name == "video_player_android") {
        val generatedJava = rootProject.layout.buildDirectory.dir("video_player_android_buffered/java")
        val prepareBufferedPlayer by tasks.registering(Sync::class) {
            from(layout.projectDirectory.dir("src/main/java"))
            include("**/*.java")
            into(generatedJava)
            filesMatching(
                listOf(
                    "**/texture/TextureVideoPlayer.java",
                    "**/platformview/PlatformViewVideoPlayer.java",
                ),
            ) {
                filter { line: String ->
                    if (line.contains(".setBackBuffer(backBufferInt")) {
                        """                      .setBufferDurationsMs(
                          50_000,
                          90_000,
                          4_000,
                          10_000)
                      .setPrioritizeTimeOverSizeThresholds(true)
 $line"""
                    } else {
                        line
                    }
                }
            }
        }

        afterEvaluate {
            extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                sourceSets.getByName("main").java.setSrcDirs(listOf(generatedJava))
            }
            tasks.matching { it.name.startsWith("compile") }.configureEach {
                dependsOn(prepareBufferedPlayer)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
