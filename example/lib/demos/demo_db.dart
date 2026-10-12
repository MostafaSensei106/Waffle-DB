import 'package:path_provider/path_provider.dart';
import 'package:waffle_db/waffle_db.dart';

/// Builds a small-footprint config for on-device demos.
WaffleConfig demoConfig({
  required String path,
  required int dimension,
  WaffleMetric metric = WaffleMetric.cosine,
  int maxElements = 50000,
}) {
  return WaffleConfig(
    dimension: dimension,
    path: path,
    graphConfig: WaffleGraphConfig(
      m: 12,
      metric: metric,
      efConstruction: 48,
      efSearch: 32,
    ),
    maxElements: maxElements,
    useQuantization: false,
    cacheSizeBytes: BigInt.from(16 * 1024 * 1024),
    workerThreads: 2,
  );
}

/// Opens (or creates) a demo database under the app documents directory.
Future<WaffleDatabase> openDemoDb({
  required String dirName,
  required WaffleSchema schema,
  required int dimension,
  WaffleMetric metric = WaffleMetric.cosine,
}) async {
  final base = await getApplicationDocumentsDirectory();
  final config = demoConfig(
    path: '${base.path}/$dirName',
    dimension: dimension,
    metric: metric,
  );
  return WaffleDatabase.open(config, schema: schema);
}
