import axios from 'axios';

export const apiClient = axios.create({
    withCredentials: true,
    headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
    }
});

export interface UserProfile {
    first_name: string;
    last_name: string;
}

export interface Family {
    id: string;
    name: string;
}

export const userService = {
    fetchProfile: () => apiClient.get<UserProfile>('/api/user/me'),
    fetchFamilies: () => apiClient.get<Family[]>('/api/families'),
};

apiClient.interceptors.response.use(
    response => response,
    error => {
        if (error.response?.status === 401) {
            window.location.href = '/auth';
        }
        return Promise.reject(error);
    }
);