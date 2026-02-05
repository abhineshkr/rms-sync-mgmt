	package com.rms.sync.jetstream.naming;

/**
 * Builds durable consumer names using a strict, deterministic convention.
 *
 * <h2>Purpose</h2>
 * JetStream durable consumers are identified by name. A stable naming scheme is critical because it:
 * <ul>
 *   <li><b>Prevents collisions</b> when many nodes create consumers in the same account/cluster.</li>
 *   <li><b>Makes bootstrapping idempotent</b>: the same node restart produces the same consumer name,
 *       enabling "create-or-update" behavior rather than creating duplicates.</li>
 *   <li><b>Improves operability</b>: operators can infer where a consumer belongs just by reading its name.</li>
 * </ul>
 *
 * <h2>Base format (LOCKED)</h2>
 * <pre>
 * &lt;consumer-tier&gt;_&lt;zone&gt;_&lt;subzone&gt;_&lt;node&gt;
 * </pre>
 *
 * <p><b>Field intent</b></p>
 * <ul>
 *   <li><b>consumer-tier</b>: logical tier of the consumer owner (e.g., leaf/subzone/zone/central).</li>
 *   <li><b>zone</b>: zone identifier (e.g., z1, z2, central).</li>
 *   <li><b>subzone</b>: subzone identifier (e.g., sz1) or {@code none} if not applicable.</li>
 *   <li><b>node</b>: unique node identifier for the consumer owner (e.g., node01).</li>
 * </ul>
 *
 * <h2>Link-specific extension</h2>
 * Some consumers are created per logical link/direction. For those, this class provides an extended
 * format that appends link metadata using a double-underscore separator to avoid ambiguity with
 * the base underscore-separated fields:
 *
 * <pre>
 * &lt;base&gt;__&lt;dir&gt;__&lt;remote-tier&gt;
 * </pre>
 *
 * <p><b>Why "__" is used</b></p>
 * <ul>
 *   <li>Underscore is already used inside the base name. Using {@code "__"} clearly separates
 *       base identity from link metadata.</li>
 *   <li>Parsing and visual inspection become straightforward.</li>
 * </ul>
 *
 * <p><b>Examples</b></p>
 * <pre>
 * zone_z1_none_zone01
 * zone_z1_none_zone01__up__subzone
 * zone_z1_none_zone01__down__central
 * </pre>
 *
 * <h2>Important constraints</h2>
 * <ul>
 *   <li>This class does <b>not</b> validate inputs. Callers should ensure values contain only safe
 *       characters for JetStream names (typically alphanumerics, dash/underscore).</li>
 *   <li>Callers should enforce that {@code subzone} is never null (use {@code "none"} when not applicable).</li>
 *   <li>Keep the format stable: changing it breaks idempotency and may orphan existing consumers.</li>
 * </ul>
 */
public final class ConsumerName {

    /**
     * Utility class: prevent instantiation.
     */
    private ConsumerName() {}

    /**
     * Builds the base durable consumer name.
     *
     * <p><b>When to use</b></p>
     * <ul>
     *   <li>Consumers that are scoped only to the local node identity (tier/zone/subzone/node).</li>
     *   <li>Consumers that do not need to encode directional/link information.</li>
     * </ul>
     *
     * <p><b>Output format</b></p>
     * <pre>
     * consumerTier_zone_subzone_node
     * </pre>
     *
     * @param consumerTier logical tier of the consumer owner (e.g., "leaf", "zone")
     * @param zone zone identifier (e.g., "z1", "central")
     * @param subzone subzone identifier (e.g., "sz1") or "none"
     * @param node unique node id (e.g., "node01")
     * @return deterministic durable consumer name
     */
    public static String of(String consumerTier, String zone, String subzone, String node) {
        // Using '_' as the primary field separator keeps the name compact and readable.
        return consumerTier + "_" + zone + "_" + subzone + "_" + node;
    }

    /**
     * Builds a link-specific durable consumer name by extending the base identity with:
     * <ul>
     *   <li>{@code dir}: the direction of the relationship (commonly "up" or "down")</li>
     *   <li>{@code remoteTier}: the logical tier on the other side of the link</li>
     * </ul>
     *
     * <p><b>Output format</b></p>
     * <pre>
     * consumerTier_zone_subzone_node__dir__remoteTier
     * </pre>
     *
     * <p><b>Why include link metadata</b></p>
     * <ul>
     *   <li>Some nodes may create multiple consumers for the same local identity, one per link/direction.</li>
     *   <li>Encoding link info avoids collisions and makes diagnosis faster.</li>
     * </ul>
     *
     * @param consumerTier logical tier of the consumer owner
     * @param zone zone identifier
     * @param subzone subzone identifier or "none"
     * @param node unique node id
     * @param dir link direction label (e.g., "up", "down")
     * @param remoteTier remote tier label (e.g., "central", "subzone")
     * @return deterministic durable consumer name including link metadata
     */
    public static String ofLink(String consumerTier, String zone, String subzone, String node,
                                String dir, String remoteTier) {
        // Reuse the base builder to guarantee consistent base formatting.
        // Append link metadata using "__" separators to clearly distinguish it from base fields.
        return of(consumerTier, zone, subzone, node) + "__" + dir + "__" + remoteTier;
    }
}