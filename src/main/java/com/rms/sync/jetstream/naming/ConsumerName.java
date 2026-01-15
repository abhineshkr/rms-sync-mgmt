package com.rms.sync.jetstream.naming;

/**
 * Consumer naming convention (LOCKED):
 * <consumer-tier>_<zone>_<subzone>_<node>
 *
 * Example: zone_z1_sz2_zone01
 */
public final class ConsumerName {
    private ConsumerName() {}

    public static String of(String consumerTier, String zone, String subzone, String node) {
        return consumerTier + "_" + zone + "_" + subzone + "_" + node;
    }
}
