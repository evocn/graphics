
// Memory

////////////////////////////////////////////////////////////////////////////////

get_host_visible_memory_type :: (using memory_properties: VkPhysicalDeviceMemoryProperties) -> index: int
{ 
    index := -1;
    for 0..memoryTypeCount-1 {
        type := memoryTypes[it];
        is_host_visible := type.propertyFlags & .HOST_VISIBLE;
        if is_host_visible {
            index = it;
            break;
        }
    }

    return index;
}
