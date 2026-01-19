package com.rms.sync.jetstream.naming;

/**
 * Consumer naming convention (LOCKED):
 * <consumer-tier>_<zone>_<subzone>_<node>
 *
 * Extended (Phase 3 adjacency model) for link-specific consumers:
 * <consumer-tier>_<zone>_<subzone>_<node>__<dir>__<remote-tier>
 *
 * Examples:
 *  zone_z1_none_zone01
 *  zone_z1_none_zone01__up__subzone
 *  zone_z1_none_zone01__down__central
 */
public final class ConsumerName {
    private ConsumerName() {}

    public static String of(String consumerTier, String zone, String subzone, String node) {
        return consumerTier + "_" + zone + "_" + subzone + "_" + node;
    }

    public static String ofLink(String consumerTier, String zone, String subzone, String node,
                                String dir, String remoteTier) {
        return of(consumerTier, zone, subzone, node) + "__" + dir + "__" + remoteTier;
    }
}
