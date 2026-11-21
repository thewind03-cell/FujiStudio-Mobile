package org.fujistudio.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val fdRegistry = FdRegistry()
    private var storageGatewayChannel: StorageGatewayChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        storageGatewayChannel?.dispose()
        storageGatewayChannel = StorageGatewayChannel(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            fdRegistry = fdRegistry,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (storageGatewayChannel?.onRequestPermissionsResult(
                requestCode,
                permissions,
                grantResults,
            ) == true
        ) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        storageGatewayChannel?.dispose()
        storageGatewayChannel = null
        fdRegistry.closeAll()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        storageGatewayChannel?.dispose()
        storageGatewayChannel = null
        fdRegistry.closeAll()
        super.onDestroy()
    }
}
