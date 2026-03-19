export interface UserProfile {
    first_name: string;
    last_name: string;
}

export interface Family {
    id: number;
    name: string;
}

export const userService = {
    fetchProfile: () => apiClient.get<UserProfile>('/api/user/me'),
    fetchFamilies: () => apiClient.get<Family[]>('/api/families'),
};