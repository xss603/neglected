#!/usr/bin/env python3
"""
calculate-node-resources-exclude-ns.py
Calculates resource requests/limits for pods on a node, excluding one namespace.
Usage: ./calculate-node-resources-exclude-ns.py <node-name> <namespace-to-exclude>
"""

import sys
import json
import subprocess
from collections import defaultdict
from typing import Dict, List, Any

def parse_cpu(value: str) -> float:
    """Convert CPU string to millicores."""
    if not value:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value) * 1000
    value = str(value)
    if value.endswith('m'):
        return float(value[:-1])
    return float(value) * 1000

def parse_memory(value: str) -> int:
    """Convert memory string to bytes."""
    if not value:
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    value = str(value)
    
    units = {
        'Ki': 1024,
        'Mi': 1024**2,
        'Gi': 1024**3,
        'Ti': 1024**4,
        'k': 1000,
        'M': 1000**2,
        'G': 1000**3,
        'T': 1000**4,
    }
    
    for suffix, multiplier in units.items():
        if value.endswith(suffix):
            return int(float(value[:-len(suffix)]) * multiplier)
    return int(value)

def get_container_resources(container: Dict) -> Dict[str, float]:
    """Extract resources from a container spec."""
    resources = container.get('resources', {})
    requests = resources.get('requests', {})
    limits = resources.get('limits', {})
    
    return {
        'cpu_req': parse_cpu(requests.get('cpu', '0')),
        'cpu_lim': parse_cpu(limits.get('cpu', '0')),
        'mem_req': parse_memory(requests.get('memory', '0')),
        'mem_lim': parse_memory(limits.get('memory', '0')),
        'gpu_req': float(requests.get('nvidia.com/gpu', 0)),
        'gpu_lim': float(limits.get('nvidia.com/gpu', 0)),
    }

def get_pod_resources(pod: Dict) -> Dict[str, float]:
    """Sum resources across all containers in a pod."""
    totals = {'cpu_req': 0, 'cpu_lim': 0, 'mem_req': 0, 'mem_lim': 0, 'gpu_req': 0, 'gpu_lim': 0}
    
    for container in pod.get('spec', {}).get('containers', []):
        res = get_container_resources(container)
        for k in totals:
            totals[k] += res[k]
    
    return totals

def main():
    if len(sys.argv) != 3:
        print("Usage: calculate-node-resources-exclude-ns.py <node-name> <namespace-to-exclude>")
        print("Example: calculate-node-resources-exclude-ns.py kind-control-plane kube-system")
        sys.exit(1)
    
    node_name = sys.argv[1]
    exclude_ns = sys.argv[2]
    
    print(f"=== Node Resource Calculator (Namespace Excluded) ===")
    print(f"Node:         {node_name}")
    print(f"Exclude NS:   {exclude_ns}")
    print()
    
    # Get node capacity
    print("--- Node Capacity ---")
    try:
        result = subprocess.run(
            ['kubectl', 'get', 'node', node_name, '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        node_data = json.loads(result.stdout)
        capacity = node_data.get('status', {}).get('capacity', {})
        print(f"  CPU:        {capacity.get('cpu', 'N/A')}")
        print(f"  Memory:     {capacity.get('memory', 'N/A')}")
        print(f"  Pods:       {capacity.get('pods', 'N/A')}")
        if 'nvidia.com/gpu' in capacity:
            print(f"  GPU:        {capacity['nvidia.com/gpu']}")
    except subprocess.CalledProcessError:
        print(f"Error: Node '{node_name}' not found")
        sys.exit(1)
    except json.JSONDecodeError:
        print("Error: Failed to parse node JSON")
        sys.exit(1)
    
    print()
    print("--- Fetching pods ---")
    
    # Get all pods on node
    try:
        result = subprocess.run(
            ['kubectl', 'get', 'pods', '--all-namespaces',
             '--field-selector', f'spec.nodeName={node_name}', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        all_pods = json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error: kubectl failed - {e}")
        sys.exit(1)
    except json.JSONDecodeError:
        print("Error: kubectl produced invalid JSON")
        sys.exit(1)
    
    total_pods = len(all_pods.get('items', []))
    excluded_pods = [p for p in all_pods.get('items', []) if p['metadata']['namespace'] == exclude_ns]
    filtered_pods = [p for p in all_pods.get('items', []) if p['metadata']['namespace'] != exclude_ns]
    
    print(f"  Total pods:     {total_pods}")
    print(f"  Excluded:       {len(excluded_pods)} ({exclude_ns})")
    print(f"  Counted:        {len(filtered_pods)}")
    print()
    
    if not filtered_pods:
        print("No pods to calculate after exclusion.")
        return
    
    if excluded_pods:
        print("--- Excluded pods ---")
        for pod in excluded_pods:
            print(f"  - {pod['metadata']['name']}")
        print()
    
    # Calculate totals
    print("--- Resource Summary ---")
    totals = {'cpu_req': 0, 'cpu_lim': 0, 'mem_req': 0, 'mem_lim': 0, 'gpu_req': 0, 'gpu_lim': 0}
    
    for pod in filtered_pods:
        res = get_pod_resources(pod)
        for k in totals:
            totals[k] += res[k]
    
    print(f"  Pods:           {len(filtered_pods)}")
    print()
    print(f"  CPU Requests:   {totals['cpu_req']/1000:.2f} cores  ({totals['cpu_req']:.0f} m)")
    print(f"  CPU Limits:     {totals['cpu_lim']/1000:.2f} cores  ({totals['cpu_lim']:.0f} m)")
    print()
    print(f"  Mem Requests:   {totals['mem_req']/1024**3:.2f} GiB")
    print(f"  Mem Limits:     {totals['mem_lim']/1024**3:.2f} GiB")
    print()
    
    if totals['gpu_req'] > 0 or totals['gpu_lim'] > 0:
        print(f"  GPU Requests:   {totals['gpu_req']:.0f}")
        print(f"  GPU Limits:     {totals['gpu_lim']:.0f}")
        print()
    
    # By namespace
    print()
    print("--- By Namespace ---")
    ns_stats = defaultdict(lambda: {'pods': 0, 'cpu': 0, 'mem': 0})
    
    for pod in filtered_pods:
        ns = pod['metadata']['namespace']
        res = get_pod_resources(pod)
        ns_stats[ns]['pods'] += 1
        ns_stats[ns]['cpu'] += res['cpu_req']
        ns_stats[ns]['mem'] += res['mem_req']
    
    for ns in sorted(ns_stats.keys()):
        stats = ns_stats[ns]
        print(f"  {ns}\t{stats['pods']} pods\t{stats['cpu']/1000:.2f} cores\t{stats['mem']/1024**2:.0f} MiB")
    
    # Top 10 pods
    print()
    print("--- Top 10 Pods by CPU Request ---")
    pod_list = []
    
    for pod in filtered_pods:
        res = get_pod_resources(pod)
        pod_list.append({
            'name': pod['metadata']['name'],
            'ns': pod['metadata']['namespace'],
            'cpu': res['cpu_req'],
            'mem': res['mem_req']
        })
    
    pod_list.sort(key=lambda x: x['cpu'], reverse=True)
    
    for pod in pod_list[:10]:
        print(f"  {pod['name']}\t{pod['ns']}\t{pod['cpu']:.0f} m\t{pod['mem']/1024**2:.0f} MiB")
    
    print()
    print("=== Done ===")

if __name__ == '__main__':
    main()
